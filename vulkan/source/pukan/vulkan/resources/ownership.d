module pukan.vulkan.resources.ownership;

import core.sync.mutex: Mutex;
import core.thread.osthread: Thread;
import pukan.vulkan.bindings;
import pukan.vulkan.resources.release: ReleaseQueue;
import pukan.vulkan.resources.vkobj: OwnerTag, VkHandleInfo, VkObj, VkParentKind;
import std.traits: FieldNameTuple;

/**
    Owns the objects that hold Vulkan handles and destroys them as a group.

    A handle is a plain value and owns nothing: `VkObj` fields inside a holder
    release it. The owner keeps its holders alive and calls `destroy` on them
    in reverse creation order, so a resource created later goes first.

    An owner that knows a device hands its releases to that device's queue, so
    a group that unloads during a frame waits for the frames in flight.

    TODO: a class field does not own its value, so a parent must call `destroy`
    on this owner before it drops; make the tree close itself.

    `threaded` locks the owner for any thread. The other variant is for one
    thread only and pays for no lock; it checks that in debug.
*/
final class ResourceOwner(bool threaded = true): OwnerTag
{
    /// One thing the owner releases: a holder or a handle taken from a slot
    private struct Entry
    {
        Object holder;
        void function(VkDevice, void*, VkAllocationCallbacks*) release;
        void* handle;
    }

    private string name;
    private Entry[] entries;
    /// Handles this owner still expects to release
    private size_t taggedHandles;

    private bool closed;
    /// Releases go through this queue; null frees at once
    private ReleaseQueue queue;

    static if(threaded)
        private Mutex mutex;
    else
        private Thread ownerThread;

    /**
        Opens an owner; `host` supplies the device its releases wait for.

        Params:
            name = label used in debug output and assertions.
            host = owner that knows the device, or null to free at once.
    */
    this(string name = null, ReleaseQueue queue = null)
    {
        this.name = name;
        this.queue = queue;

        static if(threaded)
            mutex = new Mutex;
        else
            ownerThread = Thread.getThis();
    }

    /// Sink this owner releases through, null when it frees at once
    ReleaseQueue releaseQueue() => queue;

    /// Opens a child owner that releases through the same device
    ResourceOwner!threaded open(string name)
    {
        return new ResourceOwner!threaded(name, queue);
    }

    /// Destroys what is left, so a dropped owner frees instead of leaking
    ~this()
    {
        closeUnlocked();
    }

    /**
        Depth to pass to `releaseTo` to unload everything taken after now.

        Returns: the number of holders kept so far.
    */
    size_t mark()
    {
        lockOwner();
        scope(exit) unlockOwner();

        return entries.length;
    }

    /// Takes `holder` into this owner; `releaseTo` and `close` destroy it
    void own(T : Object)(T holder)
    in(holder !is null)
    {
        lockOwner();
        {
            scope(exit) unlockOwner();

            assert(!closed, "owning into a closed ResourceOwner");
            entries ~= Entry(holder);
        }

        debug stampFields(holder);
    }

    //TODO: one level deep, and a leak cannot name the owner that missed it
    /// Debug: marks the slots of `holder` with this owner, one level deep
    private void stampFields(T)(T holder)
    {
        static foreach(name; FieldNameTuple!T)
            static if(__traits(compiles, __traits(getMember, holder, name).stamp(this)))
                __traits(getMember, holder, name).stamp(this);
    }

    /// Handles this owner still expects to release; debug only
    size_t taggedHandleCount() const => taggedHandles;

    void handleStamped()
    {
        ++taggedHandles;
    }

    void handleReleased()
    {
        --taggedHandles;
    }

    string ownerName() const => name;

    /**
        Takes the handle out of `slot` and releases it with the group.

        Params:
            slot = wrapper whose handle moves here; only device handles fit.
    */
    void accept(Handle)(ref VkObj!Handle slot)
    {
        static assert(VkHandleInfo!Handle.destroyParent == VkParentKind.device,
            "only a device handle can be accepted from a slot");

        accept(&VkObj!Handle.retire, cast(void*) slot.take());
    }

    /**
        Releases `handle` with the group, using `release` to free it.

        Params:
            release = function that frees the handle.
            handle = handle from `VkObj.take`; the owner frees it once.
    */
    void accept(void function(VkDevice, void*, VkAllocationCallbacks*) release, void* handle)
    in(handle !is null)
    {
        assert(queue !is null, "a ResourceOwner accepts handles only with a device");

        lockOwner();
        scope(exit) unlockOwner();

        assert(!closed, "accepting into a closed ResourceOwner");
        entries ~= Entry(null, release, handle);
        ++taggedHandles;
    }

    /**
        Removes `holder` without destroying it, so the caller releases it later.

        Returns: false when this owner does not keep `holder`.
    */
    bool forget(Object holder)
    {
        lockOwner();
        scope(exit) unlockOwner();

        foreach(i, entry; entries)
            if(entry.holder is holder)
            {
                entries = entries[0 .. i] ~ entries[i + 1 .. $];
                return true;
            }

        return false;
    }

    /**
        Destroys the holders taken after `mark`, newest first.

        Params:
            mark = depth from an earlier `mark`; holders taken since go away.
    */
    void releaseTo(size_t mark)
    {
        Entry[] releasing;

        lockOwner();
        {
            scope(exit) unlockOwner();

            assert(!closed, "releasing a closed ResourceOwner");
            assert(mark <= entries.length, "ResourceOwner mark is past its entries");

            releasing = entries[mark .. $];
            entries.length = mark;
        }

        releaseEntries(releasing);
    }

    /**
        Destroys every holder, newest first, and takes no more.

        A dropped owner closes itself, so an adopted owner releases its subtree.
    */
    void close()
    {
        Entry[] releasing;

        lockOwner();
        {
            scope(exit) unlockOwner();

            if(closed)
                return;

            releasing = entries;
            entries = null;
            closed = true;
        }

        releaseEntries(releasing);
    }

    /// Whether `close` has run
    bool isClosed() const => closed;

    /// Entries this owner still keeps alive
    size_t length() const => entries.length;

    /// Releases without the lock: a dropping owner is already unreachable
    private void closeUnlocked()
    {
        if(closed)
            return;

        auto releasing = entries;
        entries = null;
        closed = true;

        releaseEntries(releasing);
    }

    /// Runs outside the lock: a holder may close an owner of its own
    private void releaseEntries(Entry[] releasing)
    {
        foreach_reverse(entry; releasing)
            if(entry.holder !is null)
            {
                if(queue !is null)
                    queue.retireHolder(entry.holder);
                else
                    destroy(entry.holder);
            }
            else
            {
                --taggedHandles;
                queue.retire(entry.release, entry.handle);
            }
    }

    private void lockOwner()
    {
        static if(threaded)
            mutex.lock();
        else
            debug assert(ownerThread is Thread.getThis(),
                "ResourceOwner '" ~ name ~ "' used from another thread");
    }

    private void unlockOwner()
    {
        static if(threaded)
            mutex.unlock();
    }
}

version(unittest) private final class Recorder
{
    int[] ids;
}

version(unittest) private final class Probe
{
    private Recorder recorder;
    private int id;

    this(int id, Recorder recorder)
    {
        this.id = id;
        this.recorder = recorder;
    }

    ~this()
    {
        recorder.ids ~= id;
    }
}

unittest
{
    auto recorder = new Recorder;
    auto owner = new ResourceOwner!false("test");

    assert(owner.mark() == 0);
    owner.own(new Probe(1, recorder));

    const mark = owner.mark();
    assert(mark == 1);

    owner.own(new Probe(2, recorder));
    owner.own(new Probe(3, recorder));
    assert(owner.mark() == 3);

    // A checkpoint releases what came after it, newest first
    owner.releaseTo(mark);
    assert(recorder.ids == [3, 2]);
    assert(owner.mark() == 1);

    owner.close();
    assert(recorder.ids == [3, 2, 1]);
    assert(owner.isClosed && owner.length == 0);
}

unittest
{
    // A child owner is a holder, so closing the parent closes it too
    auto recorder = new Recorder;
    auto parent = new ResourceOwner!false("parent");
    auto child = new ResourceOwner!false("child");

    child.own(new Probe(7, recorder));
    parent.own(child);
    parent.close();

    assert(recorder.ids == [7]);
}

unittest
{
    // A forgotten holder stays alive and leaves the owner untouched
    auto recorder = new Recorder;
    auto owner = new ResourceOwner!false("parent");
    auto probe = new Probe(5, recorder);

    owner.own(probe);
    assert(owner.forget(probe));
    assert(owner.length == 0);
    assert(!owner.forget(probe));

    owner.close();
    assert(recorder.ids.length == 0);

    destroy(probe);
    assert(recorder.ids == [5]);
}

unittest
{
    // The threaded owner takes holders from one thread and releases them too
    auto recorder = new Recorder;
    auto owner = new ResourceOwner!true("threaded");

    owner.own(new Probe(1, recorder));
    owner.close();

    assert(recorder.ids == [1]);
}
