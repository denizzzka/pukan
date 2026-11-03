module pukan.vulkan.resources.ownership;

import core.sync.mutex: Mutex;
import core.thread.osthread: Thread;

/**
    Owns the objects that hold Vulkan handles and destroys them as a group.

    A handle is a plain value and owns nothing: `VkObj` fields inside a holder
    release it. The owner keeps its holders alive and calls `destroy` on them
    in reverse creation order, so a resource created later goes first.

    `threaded` locks the owner for any thread. The other variant is for one
    thread only and pays for no lock; it checks that in debug.
*/
final class ResourceOwner(bool threaded = true)
{
    private string name;
    private Object[] holders;
    private bool closed;

    static if(threaded)
        private Mutex mutex;
    else
        private Thread ownerThread;

    this(string name = null)
    {
        this.name = name;

        static if(threaded)
            mutex = new Mutex;
        else
            ownerThread = Thread.getThis();
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

        return holders.length;
    }

    /// Takes `holder` into this owner; `releaseTo` and `close` destroy it
    void own(Object holder)
    in(holder !is null)
    {
        lockOwner();
        scope(exit) unlockOwner();

        assert(!closed, "owning into a closed ResourceOwner");
        holders ~= holder;
    }

    /**
        Destroys the holders taken after `mark`, newest first.

        Params:
            mark = depth from an earlier `mark`; holders taken since go away.
    */
    void releaseTo(size_t mark)
    {
        Object[] releasing;

        lockOwner();
        {
            scope(exit) unlockOwner();

            assert(!closed, "releasing a closed ResourceOwner");
            assert(mark <= holders.length, "ResourceOwner mark is past its holders");

            releasing = holders[mark .. $];
            holders.length = mark;
        }

        // Outside the lock: a holder may close an owner of its own
        foreach_reverse(holder; releasing)
            destroy(holder);
    }

    /**
        Destroys every holder, newest first, and takes no more.

        A dropped owner closes itself, so an adopted owner releases its subtree.
    */
    void close()
    {
        Object[] releasing;

        lockOwner();
        {
            scope(exit) unlockOwner();

            if(closed)
                return;

            releasing = holders;
            holders = null;
            closed = true;
        }

        foreach_reverse(holder; releasing)
            destroy(holder);
    }

    /// Whether `close` has run
    bool isClosed() const => closed;

    /// Holders this owner still keeps alive
    size_t length() const => holders.length;

    /// Releases without the lock: a dropping owner is already unreachable
    private void closeUnlocked()
    {
        if(closed)
            return;

        auto releasing = holders;
        holders = null;
        closed = true;

        foreach_reverse(holder; releasing)
            destroy(holder);
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
    // The threaded owner takes holders from one thread and releases them too
    auto recorder = new Recorder;
    auto owner = new ResourceOwner!true("threaded");

    owner.own(new Probe(1, recorder));
    owner.close();

    assert(recorder.ids == [1]);
}
