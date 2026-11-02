module pukan.motion_matching.trajectory;

import dlib.math: Vector3f;
import pukan.motion_matching.transform: Transform, wrapAngle;
import std.algorithm: max, min;
import std.math: PI, abs;

/// A state of the character on the trajectory.
struct TrajectorySample
{
    Transform transform;
    /// Seconds relative to now; negative is history, positive is the prediction.
    float time;
}

/// Where the character has been and where it is heading.
///
/// The history is what the character actually did; the prediction is what it is about to do,
/// extrapolated from its velocity and heading. Both are needed by a query: the past explains
/// the pose, the future tells where it is going.
struct Trajectory
{
    /// Past states, oldest first.
    TrajectorySample[] history;
    /// Predicted states, nearest first.
    TrajectorySample[] prediction;

    /// How far back the history reaches, in seconds.
    float historyWindow = 0.5f;
    /// Distance between predicted states, in seconds.
    float predictionStep = 0.2f;
    /// Number of predicted states.
    uint predictionCount = 8;
    /// How fast the predicted velocity approaches the wanted one, per second.
    float acceleration = 10;
    /// How fast the predicted heading turns, radians per second.
    float turnRate = 6;

    /// Records where the character is now and rebuilds the prediction.
    ///
    /// `velocity` is what the character moves at, `wantedVelocity` and `wantedYaw` are what it
    /// is trying to reach. Nothing is traced against the world: the prediction is a straight
    /// extrapolation, which is what the first slice needs.
    void push(float dt, Transform now, Vector3f velocity, Vector3f wantedVelocity, float wantedYaw)
    {
        foreach(ref sample; history)
            sample.time -= dt;

        history ~= TrajectorySample(now, 0);

        while(history.length > 2 && -history[0].time > historyWindow)
            history = history[1 .. $];

        predict(now, velocity, wantedVelocity, wantedYaw);
    }

    /// State at `time` seconds from now, interpolated between the nearest samples;
    /// outside them it is extrapolated along the same line.
    TrajectorySample sampleAt(float time) const
    {
        if(time > 0)
        {
            if(prediction.length > 0)
                return interpolate(prediction, time);
        }
        else if(history.length > 0)
            return interpolate(history, time);

        return TrajectorySample(Transform.identity, time);
    }

    private void predict(Transform now, Vector3f velocity, Vector3f wantedVelocity, float wantedYaw)
    {
        prediction.length = 0;

        if(predictionCount == 0 || predictionStep <= 0)
            return;

        // Long prediction steps would make the velocity jump, so each of them is integrated
        // in small pieces
        enum substepTime = 0.02f;
        const uint substeps = max(1u, cast(uint) (predictionStep / substepTime));
        const float substep = predictionStep / substeps;

        auto state = now;
        auto speed = velocity;
        auto yaw = now.yaw;

        foreach(i; 0 .. predictionCount)
        {
            foreach(j; 0 .. substeps)
            {
                speed += (wantedVelocity - speed) * min(1.0f, acceleration * substep);
                state.translation += speed * substep;

                auto turn = wrapAngle(wantedYaw - yaw);
                const float maxTurn = turnRate * substep;
                turn = turn > maxTurn ? maxTurn : (turn < -maxTurn ? -maxTurn : turn);
                yaw += turn;
                state.yaw = yaw;
            }

            prediction ~= TrajectorySample(state, (i + 1) * predictionStep);
        }
    }
}

private TrajectorySample interpolate(const(TrajectorySample)[] samples, float time)
{
    if(samples.length == 1)
        return TrajectorySample(samples[0].transform, time);

    size_t upper;

    while(upper < samples.length && samples[upper].time < time)
        ++upper;

    size_t lower;

    if(upper == 0)
    {
        lower = 0;
        upper = 1;
    }
    else if(upper == samples.length)
    {
        lower = samples.length - 2;
        upper = samples.length - 1;
    }
    else
        lower = upper - 1;

    const a = samples[lower];
    const b = samples[upper];
    const span = b.time - a.time;
    const t = span != 0 ? (time - a.time) / span : 0;

    return TrajectorySample(Transform.lerp(a.transform, b.transform, t), time);
}

unittest
{
    Trajectory trajectory;
    trajectory.predictionCount = 4;
    trajectory.predictionStep = 0.2f;

    const now = Transform(Vector3f(0, 0, 0), 0);
    trajectory.push(1.0f / 60, now, Vector3f(0, 0, 2), Vector3f(0, 0, 2), 0);

    assert(trajectory.prediction.length == 4);
    assert(abs(trajectory.prediction[0].time - 0.2f) < 1e-6);

    // The character keeps its speed, so the prediction is a straight line at 2 m/s
    assert(abs(trajectory.prediction[0].transform.translation.z - 0.4f) < 1e-4);
    assert(abs(trajectory.prediction[3].transform.translation.z - 1.6f) < 1e-3);

    // The current time is the current state
    assert(trajectory.sampleAt(0).transform.translation.z == 0);

    // Half a step between two samples is halfway between them
    assert(abs(trajectory.sampleAt(0.1f).transform.translation.z - 0.2f) < 1e-3);
}

unittest
{
    Trajectory trajectory;
    trajectory.predictionCount = 2;
    trajectory.predictionStep = 0.2f;
    trajectory.turnRate = 100;

    // Standing still and turning a quarter to the right
    trajectory.push(1.0f / 60, Transform.identity, Vector3f(0, 0, 0), Vector3f(0, 0, 0), PI / 2);

    assert(trajectory.prediction.length == 2);
    assert(abs(trajectory.prediction[0].transform.yaw - PI / 2) < 1e-3);
    assert(trajectory.prediction[0].transform.translation.length < 1e-3);
}

unittest
{
    Trajectory trajectory;

    trajectory.push(0.1f, Transform(Vector3f(0, 0, 0), 0), Vector3f(0, 0, 2), Vector3f(0, 0, 2), 0);
    trajectory.push(0.1f, Transform(Vector3f(0, 0, 0.2f), 0), Vector3f(0, 0, 2), Vector3f(0, 0, 2), 0);

    // The first state is now a tenth of a second old
    assert(trajectory.history.length == 2);
    assert(abs(trajectory.history[0].time + 0.1f) < 1e-6);
    assert(trajectory.history[0].transform.translation.z == 0);

    assert(abs(trajectory.sampleAt(-0.1f).transform.translation.z) < 1e-6);
    assert(abs(trajectory.sampleAt(-0.05f).transform.translation.z - 0.1f) < 1e-6);
}
