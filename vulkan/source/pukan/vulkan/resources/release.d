module pukan.vulkan.resources.release;

import core.memory: GC;
import core.stdc.stdlib: free, malloc, realloc;
import core.sync.mutex: Mutex;
import pukan.vulkan.bindings;

/**
    Holds handle releases until the frames in flight can no longer use them.

    A destructor often runs while a command buffer still reads what it frees,
    so it queues the handle instead of calling into the driver. The queue
    survives the device: once the device is gone, releases are dropped.
*/
final class ReleaseQueue
{
    /// A release queued until no frame in flight can still reference it
    private struct Entry
    {
        /// Null for a holder, whose destructor releases what it owns
        void function(VkDevice, void*, VkAllocationCallbacks*) release;
        void* handle;
        Object holder;
        uint age;
    }

    private VkDevice vkDevice;
    private VkAllocationCallbacks* alloc;

    /// C heap: a finalizer retires while the GC forbids its own allocation
    private Entry* entries;
    private size_t count;
    private size_t capacity;

    /// Entries taken for release, kept off the GC heap for the same reason
    private Entry* releasing;
    private size_t releasingCount;
    private size_t releasingCapacity;

    private Mutex mutex;
    private bool closed;
    private bool flushing;

    this(VkDevice device, VkAllocationCallbacks* alloc)
    {
        this.vkDevice = device;
        this.alloc = alloc;
        mutex = new Mutex;

        capacity = 4096;
        entries = allocate(capacity);
        releasingCapacity = capacity;
        releasing = allocate(releasingCapacity);
    }

    ~this()
    {
        dropRoots(releasing[0 .. releasingCount]);
        dropRoots(entries[0 .. count]);

        if(entries !is null)
            free(entries);

        if(releasing !is null)
            free(releasing);
    }

    /// The device this queue releases into, valid until `close`
    VkDevice device() => vkDevice;

    /// The allocator every release goes through
    VkAllocationCallbacks* allocator() => alloc;

    /// Whether the device this queue served is gone
    bool isClosed() const => closed;

    /// Queues a handle release for the next flush that outlives a frame in flight
    void retire(void function(VkDevice, void*, VkAllocationCallbacks*) release, void* handle)
    {
        if(closed)
            return;

        synchronized(mutex)
        {
            reserve(entries, count, capacity);
            entries[count++] = Entry(release, handle);
        }
    }

    /// Queues a holder, whose destructor releases what it owns
    void retireHolder(Object holder)
    {
        if(closed || holder is null)
            return;

        // A collector sweep runs this when the holder may be freed already;
        // its own finalizer releases the slots it owns.
        if(GC.inFinalizer)
            return;

        synchronized(mutex)
        {
            reserve(entries, count, capacity);
            // A C-heap entry is not scanned, so liveness comes from a root
            GC.addRoot(cast(void*) holder);
            entries[count++] = Entry(null, null, holder);
        }
    }

    /// Runs the queued releases no frame in flight can still reference
    void flush(uint framesInFlight)
    {
        synchronized(mutex)
        {
            if(flushing)
                return;

            foreach(ref entry; entries[0 .. count])
                ++entry.age;

            size_t taken;

            while(taken < count && entries[taken].age > framesInFlight)
                ++taken;

            if(taken == 0)
                return;

            flushing = true;

            if(taken > releasingCapacity)
                releasing = resize(releasing, taken, releasingCapacity);

            foreach(i; 0 .. taken)
                releasing[i] = entries[i];

            releasingCount = taken;

            foreach(i; 0 .. count - taken)
                entries[i] = entries[i + taken];

            count -= taken;
        }

        scope(exit) synchronized(mutex) flushing = false;

        // Outside the lock, because a holder's destructor may retire again
        foreach(ref entry; releasing[0 .. releasingCount])
            if(entry.release !is null)
                entry.release(vkDevice, entry.handle, alloc);
            else if(entry.holder !is null)
            {
                GC.removeRoot(cast(void*) entry.holder);
                destroy(entry.holder);
            }

        releasingCount = 0;
    }

    /// Whether a release still waits for the frames in flight
    bool hasRetired() const
    {
        synchronized(mutex)
            return count > 0;
    }

    /// Drops what is left; the device it served is about to die
    void close()
    {
        synchronized(mutex)
            closed = true;
    }

    /// Grows a C-heap buffer to fit one more entry
    private static void reserve(ref Entry* buffer, size_t used, ref size_t size)
    {
        if(used < size)
            return;

        buffer = resize(buffer, used + 1, size);
    }

    private static Entry* resize(Entry* buffer, size_t needed, ref size_t size)
    {
        while(size < needed)
            size *= 2;

        auto grown = cast(Entry*) realloc(buffer, size * Entry.sizeof);
        assert(grown !is null, "a release queue ran out of memory");

        return grown;
    }

    private static Entry* allocate(size_t size)
    {
        auto buffer = cast(Entry*) malloc(size * Entry.sizeof);
        assert(buffer !is null, "a release queue ran out of memory");

        return buffer;
    }

    private static void dropRoots(Entry[] queued)
    {
        foreach(ref entry; queued)
            if(entry.release is null && entry.holder !is null)
                GC.removeRoot(cast(void*) entry.holder);
    }
}

unittest
{
    static final class Holder
    {
        static size_t destroyed;
        ~this() { ++destroyed; }
    }

    static final class Owner
    {
        ReleaseQueue queue;
        Object held;
        ~this()
        {
            if(queue !is null)
                queue.retireHolder(held);
        }
    }

    void abandon(ReleaseQueue queue)
    {
        auto owner = new Owner;
        owner.queue = queue;
        owner.held = new Holder;
    }

    Holder.destroyed = 0;

    auto queue = new ReleaseQueue(VkDevice.init, null);

    // A queued holder stays alive through a collection and goes on flush
    {
        auto holder = new Holder;
        queue.retireHolder(holder);
        GC.collect();
        assert(Holder.destroyed == 0, "a queued holder must outlive a collection");
        assert(queue.hasRetired);
        queue.flush(0);
        assert(Holder.destroyed == 1);
    }

    // A finalizer must not queue a child the sweep may have freed already
    abandon(queue);
    GC.collect();
    assert(!queue.hasRetired, "a finalizer must not resurrect a swept holder");

    queue.close();
}
