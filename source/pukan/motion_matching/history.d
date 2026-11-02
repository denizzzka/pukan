module pukan.motion_matching.history;

import dlib.math: Vector3f;
import std.math: abs;

/// One moment of the history: where every bone of the schema was, measured from the root bone.
struct HistoryFrame
{
    /// Seconds relative to now; never positive.
    float time;
    /// One position per bone, in the root's space.
    Vector3f[] positions;
}

/// Recent bone positions, measured from the root bone.
///
/// A position is kept as it was relative to the root at that same moment, so the root's own
/// motion does not leak into it. Its world position is that value moved by the root transform
/// the trajectory gives for the same time.
struct PoseHistory
{
    /// Frames, oldest first.
    HistoryFrame[] frames;
    /// How far back the history reaches, in seconds.
    float window = 0.5f;

    /// Records the current bone positions.
    void push(float dt, const(Vector3f)[] positions)
    {
        foreach(ref frame; frames)
            frame.time -= dt;

        frames ~= HistoryFrame(0, positions.dup);

        while(frames.length > 2 && -frames[0].time > window)
            frames = frames[1 .. $];
    }

    /// Bone positions at `time` seconds from now, interpolated between the nearest frames;
    /// outside the history the nearest frame is taken as is.
    Vector3f[] sampleAt(float time) const
    {
        if(frames.length == 0)
            return null;

        if(time <= frames[0].time)
            return frames[0].positions.dup;

        if(time >= frames[$ - 1].time)
            return frames[$ - 1].positions.dup;

        size_t upper;

        while(upper < frames.length && frames[upper].time < time)
            ++upper;

        const lower = upper - 1;
        const a = frames[lower];
        const b = frames[upper];

        assert(a.positions.length == b.positions.length);

        const span = b.time - a.time;
        const t = span != 0 ? (time - a.time) / span : 0;

        Vector3f[] result;
        result.length = a.positions.length;

        foreach(i; 0 .. result.length)
            result[i] = a.positions[i] + (b.positions[i] - a.positions[i]) * t;

        return result;
    }
}

unittest
{
    PoseHistory history;

    history.push(0.1f, [Vector3f(0, 1, 0)]);
    history.push(0.1f, [Vector3f(0, 1.2f, 0)]);

    assert(history.frames.length == 2);

    // The newest frame is now, the older one is a tenth of a second back
    assert(abs(history.sampleAt(0)[0].y - 1.2f) < 1e-6);
    assert(abs(history.sampleAt(-0.1f)[0].y - 1) < 1e-6);

    // Halfway between the two frames is halfway between the two heights
    assert(abs(history.sampleAt(-0.05f)[0].y - 1.1f) < 1e-6);

    // Beyond the oldest frame, the oldest frame is used
    assert(abs(history.sampleAt(-1)[0].y - 1) < 1e-6);
}

unittest
{
    PoseHistory history;

    // Frames older than the window are dropped, two are always kept
    history.window = 0.2f;

    foreach(i; 0 .. 100)
        history.push(1.0f / 60, [Vector3f(0, cast(float) i, 0)]);

    assert(history.frames.length > 2);
    assert(history.frames.length < 20);
    assert(abs(history.frames[0].time + 0.2f) <= 1.0f / 60 + 1e-6);
    assert(abs(history.sampleAt(0)[0].y - 99) < 1e-6);
}
