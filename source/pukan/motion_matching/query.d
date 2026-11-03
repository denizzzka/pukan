module pukan.motion_matching.query;

import dlib.math: Vector3f;
import pukan.graphics.g3d.axes: Axis, onPlane, planeComponents;
import pukan.motion_matching.database: putPosition;
import pukan.motion_matching.history: PoseHistory;
import pukan.motion_matching.schema: Schema;
import pukan.motion_matching.trajectory: Trajectory;
import std.algorithm: min;

/// One channel vector describing the character right now, laid out like a database vector.
struct Query
{
    /// Up axis the vector was built for; the database must share it
    Axis up;
    float[] values;
}

/// Fills `query` from the trajectory and the recent poses.
///
/// The root of the query is the character's own transform; bone positions are measured from
/// it, the same way the database measures them from the clip's root bone.
void buildQuery(ref Query query, Schema schema, Axis up, const Trajectory trajectory, const PoseHistory history)
{
    const dimensions = schema.dimensions;
    const float step = schema.derivativeStep;

    query.up = up;
    query.values.length = dimensions;
    query.values[] = 0;
    size_t index;

    const now = trajectory.sampleAt(0).transform;

    foreach(ref channel; schema.trajectory)
    {
        const at = trajectory.sampleAt(channel.offset).transform;
        const position = up.onPlane(now.applyInverse(up, at.translation));

        if(channel.position)
            putPosition(query.values, index, position);

        if(channel.velocity)
        {
            const before = trajectory.sampleAt(channel.offset - step).transform;
            const positionBefore = up.onPlane(now.applyInverse(up, before.translation));
            putPosition(query.values, index, (position - positionBefore) / step);
        }

        if(channel.heading)
        {
            const heading = now.rotateInverse(up, at.forward(up));
            const plane = up.planeComponents(heading);
            query.values[index] = plane[0];
            query.values[index + 1] = plane[1];
            index += 2;
        }
    }

    auto positions = history.sampleAt(0);
    auto positionsBefore = history.sampleAt(-step);

    foreach(boneIdx, ref channel; schema.bones)
    {
        if(boneIdx >= positions.length)
            break;

        auto position = positions[boneIdx];

        if(channel.position)
            putPosition(query.values, index, position);

        // A bone's velocity is its motion relative to the body, without the root's own
        // displacement: the same measure the database takes
        if(channel.velocity)
        {
            auto positionBefore = position;

            if(positionsBefore.length > 0)
                positionBefore = positionsBefore[min(boneIdx, positionsBefore.length - 1)];

            putPosition(query.values, index, (position - positionBefore) / step);
        }
    }
}

unittest
{
    import pukan.motion_matching.database: Clip, ClipPose, Database;
    import pukan.motion_matching.schema: BoneChannel, TrajectoryChannel;
    import pukan.motion_matching.transform: Transform;
    import std.math: abs, sin;

    enum up = Axis.y;

    // Root slides along +Z at 2 m/s, a single bone bobs above it
    static ClipPose sampleStraightLine(size_t clip, float time)
    {
        enum duration = 2;

        time = time < 0 ? 0 : (time > duration ? duration : time);

        ClipPose result;
        result.root = Transform(Vector3f(0, 0, 2 * time), 0);
        result.bones = [Vector3f(0, 0.1f + 0.05f * sin(time * 3.0f), 0)];
        return result;
    }

    Schema schema;
    schema.bones = [BoneChannel("foot", true, true, 1)];
    schema.trajectory = [
        TrajectoryChannel(-0.4, true, false, false, 1),
        TrajectoryChannel(0.35, true, true, true, 1),
    ];

    Database database;
    database.build(schema, up, [Clip("run", 2)], &sampleStraightLine);

    // Nothing else in the clip moves like the character does at t = 1: the path is straight
    // but the bone keeps changing, so the right pose is the only one that fits
    Trajectory trajectory;
    PoseHistory history;

    enum dt = 1.0f / 60;
    enum targetTime = 1.0f;
    enum historyStart = targetTime - 0.6f;

    for(float time = historyStart; time <= targetTime + dt / 2; time += dt)
        history.push(dt, [Vector3f(0, 0.1f + 0.05f * sin(time * 3.0f), 0)]);

    for(float time = historyStart; time <= targetTime + dt / 2; time += dt)
        trajectory.push(dt, Transform(Vector3f(0, 0, 2 * time), 0), Vector3f(0, 0, 2), Vector3f(0, 0, 2), 0);

    Query query;
    buildQuery(query, schema, up, trajectory, history);

    assert(query.values.length == schema.dimensions);

    size_t nearest;
    float best = float.max;

    foreach(i; 0 .. database.samples.length)
    {
        const distance = database.distance(i, query.values);
        if(distance < best)
        {
            best = distance;
            nearest = i;
        }
    }

    // The character matches the pose it is in, and nothing else comes close
    assert(abs(database.samples[nearest].time - targetTime) <= 2 * dt);
    assert(best < 1e-4);
}
