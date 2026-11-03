module pukan.vulkan.resources.sharing;

import core.sync.mutex: Mutex;
import pukan.vulkan.resources.release: ReleaseQueue;

/**
    One resource that several holders share.

    A holder takes the node once and drops it in its own destructor, so the
    count follows the object graph instead of matching calls in two places.
    The last drop releases the value through `releaser`.

    TODO: hand out `const` and, where nothing writes after the upload,
    `immutable`, so a holder cannot change a value another holder reads and a
    worker can pass it on. `const` does not pass through the draw path yet.
*/
final class SharedResource(T)
{
    private T resource;
    private void delegate(T) releaser;
    private size_t users;
    private Mutex mutex;

    this(T resource, void delegate(T) releaser)
    in(releaser !is null)
    {
        static if(is(T : Object))
            assert(resource !is null, "a shared resource needs a value");

        this.resource = resource;
        this.releaser = releaser;
        mutex = new Mutex;
    }

    /// The shared value; a holder only reads it
    T value() => resource;

    /// Adds a holder; true when it is the first, so it may upload the value
    bool acquire()
    {
        synchronized(mutex)
            return ++users == 1;
    }

    /// Drops a holder; the last one releases the value
    void release()
    {
        bool last;

        synchronized(mutex)
        {
            assert(users > 0, "releasing a shared resource nobody holds");
            last = --users == 0;
        }

        if(last)
            releaser(resource);
    }

    /// Holders that still keep the value alive
    size_t userCount()
    {
        synchronized(mutex)
            return users;
    }
}

unittest
{
    int released;
    auto node = new SharedResource!int(7, (int v) { released += v; });

    assert(node.value == 7);
    assert(node.acquire());
    assert(!node.acquire());
    assert(node.userCount == 2);

    node.release();
    assert(released == 0);

    node.release();
    assert(released == 7);
    assert(node.userCount == 0);
}
