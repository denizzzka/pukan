module pukan.motion_matching.search;

import dlib.math: Vector3f;
import pukan.motion_matching.database: Database, invalidSample;
import pukan.motion_matching.query: Query;
import pukan.motion_matching.schema: Schema;
import std.math: sqrt;

/// One pose a search can choose.
struct FoundPose
{
    /// Index into `Database.samples`, `invalidSample` when there is none.
    size_t sample = invalidSample;
    /// Weighted distance plus the biases that applied.
    float cost;
}

/// Weighted distance from one stored pose to the query, with the pose's own bias.
float score(const Database database, size_t sample, const Query query)
{
    assert(query.values.length == database.dimensionWeights.length);

    return database.distance(sample, query.values) + database.samples[sample].bias;
}

/// Cheapest pose of the database; false when the database holds no pose.
bool findNearest(const Database database, const Query query, out FoundPose found)
{
    assert(database.up == query.up, "the query and the database were built for different up axes");

    bool any;

    foreach(sample; 0 .. database.samples.length)
    {
        const cost = score(database, sample, query);

        if(!any || cost < found.cost)
        {
            found = FoundPose(sample, cost);
            any = true;
        }
    }

    return any;
}

/// Cost of the pose that is playing already: it carries the bias for not interrupting it.
bool evaluateCurrent(const Database database, const Query query, size_t sample, out FoundPose found)
{
    if(sample == invalidSample)
        return false;

    found = FoundPose(sample, score(database, sample, query) + database.keepPlayingBias);
    return true;
}

/// Velocity of the root that a pose vector describes right now, in the root's own space.
/// Zero when the schema has no trajectory velocity at the present moment.
Vector3f currentVelocity(const Schema schema, const(float)[] pose)
{
    size_t offset;

    foreach(ref channel; schema.trajectory)
    {
        const bool present = channel.offset == 0;

        if(channel.position)
        {
            if(present && channel.velocity)
                return Vector3f(pose[offset], pose[offset + 1], pose[offset + 2]);

            offset += 3;
        }

        if(channel.velocity)
        {
            if(present)
                return Vector3f(pose[offset], pose[offset + 1], pose[offset + 2]);

            offset += 3;
        }

        if(channel.heading)
            offset += 2;
    }

    return Vector3f(0, 0, 0);
}

/// How fast the chosen pose has to play to cover the distance the query asks for: the ratio
/// between the two trajectory speeds, clamped. One when the pose stands still.
float playRate(const Schema schema, const(float)[] query, const(float)[] pose, float minRate, float maxRate)
{
    float querySpeed = 0;
    float poseSpeed = 0;
    size_t offset;

    foreach(ref channel; schema.trajectory)
    {
        if(channel.position)
            offset += 3;

        if(channel.velocity)
        {
            querySpeed += lengthAt(query, offset);
            poseSpeed += lengthAt(pose, offset);
            offset += 3;
        }

        if(channel.heading)
            offset += 2;
    }

    const rate = poseSpeed > 1e-3f ? querySpeed / poseSpeed : 1.0f;

    return rate < minRate ? minRate : (rate > maxRate ? maxRate : rate);
}

private float lengthAt(const(float)[] values, size_t offset)
{
    return sqrt(
        values[offset] * values[offset]
        + values[offset + 1] * values[offset + 1]
        + values[offset + 2] * values[offset + 2]
    );
}

unittest
{
    import dlib.math: Vector3f;
    import pukan.graphics.g3d.axes: Axis;
    import pukan.motion_matching.database: Clip, ClipPose;
    import pukan.motion_matching.schema: BoneChannel, TrajectoryChannel;
    import pukan.motion_matching.transform: Transform;
    import std.math: abs, sin;

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

    enum up = Axis.y;

    Schema schema;
    schema.bones = [BoneChannel("foot", true, true, 1)];
    schema.trajectory = [TrajectoryChannel(0.35, true, true, true, 1)];

    Database database;
    database.build(schema, up, [Clip("run", 2)], &sampleStraightLine);

    Query query;
    query.up = up;

    // The pose itself as a query finds itself, with only its bias as the cost
    query.values = database.vectors[30 * 14 .. 31 * 14].dup;

    FoundPose found;
    assert(findNearest(database, query, found));
    assert(found.sample == 30);
    assert(abs(found.cost - database.samples[30].bias) < 1e-4f);

    // A pose biased out of the way loses to a neighbour even when it fits better
    database.samples[30].bias = 10;
    assert(findNearest(database, query, found));
    assert(found.sample != 30);

    database.samples[30].bias = 0;

    // Keeping the current pose is free until the database says otherwise
    assert(evaluateCurrent(database, query, 30, found));
    assert(found.sample == 30);

    database.keepPlayingBias = 100;
    assert(evaluateCurrent(database, query, 30, found));

    // The current pose costs its own distance, its bias and the price of interrupting it
    assert(found.cost == 100);
}

unittest
{
    import dlib.math: Vector3f;
    import pukan.graphics.g3d.axes: Axis;
    import pukan.motion_matching.database: Clip, ClipPose;
    import pukan.motion_matching.schema: BoneChannel;
    import pukan.motion_matching.transform: Transform;
    import std.math: abs;

    static ClipPose sampleStill(size_t clip, float time)
    {
        ClipPose result;
        result.root = Transform.identity;
        result.bones = [Vector3f(0, 0, 0)];
        return result;
    }

    enum up = Axis.y;

    Schema schema;
    schema.bones = [BoneChannel("foot")];

    Database database;
    database.build(schema, up, [Clip("loop", 1), Clip("once", 1, false)], &sampleStill);

    // One second at 30 Hz, both ends included
    assert(database.ranges.length == 2);
    assert(database.ranges[0].first == 0 && database.ranges[0].count == 31);
    assert(database.ranges[1].first == 31 && database.ranges[1].count == 31);

    assert(database.sampleIndex(0, 0) == 0);
    assert(database.sampleIndex(0, 0.5f) == 15);

    // A looping clip wraps its time, so its end is its start
    assert(database.sampleIndex(0, 1) == 0);
    assert(database.sampleIndex(0, 1.5f) == 15);
    assert(database.sampleIndex(0, -0.5f) == 15);

    // A one shot clamps to its last sample
    assert(database.sampleIndex(1, 1) == 61);
    assert(database.sampleIndex(1, 1.5f) == 61);

    assert(database.sampleIndex(5, 0) == invalidSample);
}

unittest
{
    import pukan.motion_matching.schema: TrajectoryChannel;
    import std.math: abs;

    // The only channel is the speed of the trajectory
    Schema schema;
    schema.trajectory = [TrajectoryChannel(0, false, true, false, 1)];

    const(float)[] faster = [0, 0, 4];
    const(float)[] sameSpeed = [0, 0, 2];
    const(float)[] halfSpeed = [0, 0, 1];

    assert(abs(playRate(schema, sameSpeed, sameSpeed, 0.5f, 1.5f) - 1) < 1e-6f);

    // A slower query or a faster pose hits the bottom of the interval, and the reverse the top
    assert(abs(playRate(schema, halfSpeed, sameSpeed, 0.5f, 1.5f) - 0.5f) < 1e-6f);
    assert(abs(playRate(schema, faster, sameSpeed, 0.5f, 1.5f) - 1.5f) < 1e-6f);

    // A pose that stands still keeps its rate
    const(float)[] still = [0, 0, 0];
    assert(playRate(schema, sameSpeed, still, 0.5f, 1.5f) == 1);
}
