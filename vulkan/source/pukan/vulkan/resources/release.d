module pukan.vulkan.resources.release;

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

    /// Filled in place, because a destructor may retire during a collection
    private Entry[] entries;
    private size_t count;
    private Mutex mutex;
    private bool closed;

    this(VkDevice device, VkAllocationCallbacks* alloc)
    {
        this.vkDevice = device;
        this.alloc = alloc;
        mutex = new Mutex;
        entries.length = 4096;
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
            if(count < entries.length)
            {
                entries[count++] = Entry(release, handle);
                return;
            }
        }

        // The queue is full, so the handle goes now rather than never
        //TODO: a burst can put a handle back in flight; grow instead of freeing
        release(vkDevice, handle, alloc);
    }

    /// Queues a holder, whose destructor releases what it owns
    void retireHolder(Object holder)
    {
        if(closed)
            return;

        synchronized(mutex)
        {
            if(count < entries.length)
            {
                entries[count++] = Entry(null, null, holder);
                return;
            }
        }

        destroy(holder);
    }

    /// Runs the queued releases no frame in flight can still reference
    void flush(uint framesInFlight)
    {
        synchronized(mutex)
        {
            foreach(i; 0 .. count)
                ++entries[i].age;

            while(count && entries[0].age > framesInFlight)
            {
                auto entry = entries[0];
                const rest = count - 1;

                foreach(i; 0 .. rest)
                    entries[i] = entries[i + 1];

                count = rest;

                if(entry.release !is null)
                    entry.release(vkDevice, entry.handle, alloc);
                else
                    destroy(entry.holder);
            }
        }
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
}
