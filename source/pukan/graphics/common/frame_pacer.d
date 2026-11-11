module pukan.graphics.common.frame_pacer;

import core.time: Duration, MonoTime, dur;
import std.math: isFinite;

/// Keeps a target from starting frames faster than its rate allows
struct FramePacer
{
    private double rate; // frames per second, zero when unlimited
    private Duration period; // one frame at that rate
    private MonoTime nextStart;
    private bool scheduled;

    /// Frames per second ceiling; zero or less leaves pacing to the present mode
    @property double fps() const => rate;

    /// A new rate restarts the schedule, so the next frame starts without delay
    @property void fps(double value)
    {
        rate = value > 0 && value.isFinite ? value : 0.0;

        if(rate > 0)
        {
            const nsecs = cast(long) (1_000_000_000.0 / rate);
            period = dur!"nsecs"(nsecs > 0 ? nsecs : 1);
        }
        else
            period = Duration.zero;

        scheduled = false;
    }

    /// Returns the time to wait before the next frame may start; advances the schedule
    Duration nextDelay(MonoTime now)
    {
        if(period <= Duration.zero)
            return Duration.zero;

        if(!scheduled)
        {
            scheduled = true;
            nextStart = now;
        }

        const delay = nextStart > now ? nextStart - now : Duration.zero;

        // Step from the deadline, not from now, so oversleeping does not drift.
        // A stalled frame loses its backlog instead of bursting afterwards.
        nextStart += period;
        if(nextStart < now)
            nextStart = now + period;

        return delay;
    }

    /// Sleeps until the next frame may start
    void waitNextFrame()
    {
        import core.thread: Thread;

        const delay = nextDelay(MonoTime.currTime);
        if(delay > Duration.zero)
            Thread.sleep(delay);
    }

    /// Forgets the schedule; the next frame starts immediately
    void reset()
    {
        scheduled = false;
    }
}

unittest
{
    import core.time: msecs;

    FramePacer pacer;
    pacer.fps = 100; // 10 ms
    assert(pacer.fps == 100);

    auto now = MonoTime.currTime;

    // The first frame starts at once and opens the schedule
    assert(pacer.nextDelay(now) == Duration.zero);
    assert(pacer.nextDelay(now + msecs(4)) == msecs(6));
    assert(pacer.nextDelay(now + msecs(20)) == Duration.zero);

    // A frame that overran its deadline waits for nothing and keeps no backlog
    assert(pacer.nextDelay(now + msecs(55)) == Duration.zero);
    assert(pacer.nextDelay(now + msecs(56)) == msecs(9));

    // Changing the rate starts a fresh schedule
    pacer.fps = 50; // 20 ms
    assert(pacer.nextDelay(now + msecs(56)) == Duration.zero);
    assert(pacer.nextDelay(now + msecs(60)) == msecs(16));

    pacer.fps = 0;
    assert(pacer.fps == 0);
    assert(pacer.nextDelay(now) == Duration.zero);
}
