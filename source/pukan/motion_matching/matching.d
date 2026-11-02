module pukan.motion_matching.matching;

import pukan.motion_matching.database: Database, invalidSample;
import pukan.motion_matching.query: Query;
import pukan.motion_matching.search: FoundPose, evaluateCurrent, findNearest, playRate;

/// What one step decided.
struct Decision
{
    /// Pose to start playing now; `invalidSample` when the current one continues.
    size_t sample = invalidSample;
    /// How fast to play the pose that is now current.
    float playRate = 1;
    /// Cost of the pose that is now current, biases included.
    float cost;
}

/// The per-frame state of one matching character.
///
/// The pose that is playing competes with the whole database: it wins unless another pose
/// fits the query well enough to pay the price of interrupting it. A full search is not run
/// every frame, only when the interval elapsed or the current pose cannot be continued.
struct Matching
{
    /// Index into `Database.samples` of the pose playing now, `invalidSample` before the
    /// first search. The caller keeps it in step with the playback time through
    /// `Database.sampleIndex`.
    size_t currentSample = invalidSample;
    /// Seconds since the last search handed the choice to the database.
    float sinceSearch = 0;
    /// Seconds between searches while the current pose can continue.
    float searchInterval = 0.1f;
    /// Slowest and fastest playback rate.
    float minRate = 0.5f;
    float maxRate = 1.5f;

    /// Chooses the pose to play and how fast. Updates `currentSample` and `sinceSearch`.
    Decision step(const Database database, const Query query, float dt)
    {
        sinceSearch += dt;

        FoundPose best;
        const bool hasBest = findNearest(database, query, best);

        FoundPose current;
        const bool hasCurrent = evaluateCurrent(database, query, currentSample, current);

        Decision decision;

        // Without a pose of its own the character has nothing to continue, so the first
        // search does not wait
        const bool due = !hasCurrent || sinceSearch >= searchInterval;

        if(due && hasBest && (!hasCurrent || best.cost < current.cost))
        {
            decision.sample = best.sample;
            currentSample = best.sample;
            sinceSearch = 0;
        }

        const chosen = currentSample != invalidSample
            ? currentSample
            : (hasBest ? best.sample : invalidSample);

        if(chosen != invalidSample)
            decision.playRate = playRate(
                database.schema,
                query.values,
                database.vectorOf(chosen),
                minRate,
                maxRate,
            );

        if(chosen == currentSample && hasCurrent)
            decision.cost = current.cost;
        else if(hasBest && chosen == best.sample)
            decision.cost = best.cost;

        return decision;
    }
}

unittest
{
    import dlib.math: Vector3f;
    import pukan.axes: Axis;
    import pukan.motion_matching.database: Clip, ClipPose;
    import pukan.motion_matching.query: Query;
    import pukan.motion_matching.schema: BoneChannel, Schema, TrajectoryChannel;
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
    query.values = database.vectors[30 * 14 .. 31 * 14].dup;

    Matching matching;
    matching.searchInterval = 0.1f;

    // The first step has nothing to continue, so it takes the best pose right away
    const first = matching.step(database, query, 0.016f);
    assert(first.sample == 30);
    assert(matching.currentSample == 30);
    assert(abs(first.playRate - 1) < 1e-6f);

    // The same query within the interval keeps the pose, with no second search
    const second = matching.step(database, query, 0.016f);
    assert(second.sample == invalidSample);
    assert(matching.currentSample == 30);

    // Once the interval elapses the same pose still wins: no jump
    const third = matching.step(database, query, 0.1f);
    assert(third.sample == invalidSample);

    // A query that only another pose fits wins after the interval, and pays for the jump
    Query far;
    far.up = up;
    far.values = database.vectors[10 * 14 .. 11 * 14].dup;

    const jumped = matching.step(database, far, 0.1f);
    assert(jumped.sample == 10);
    assert(matching.currentSample == 10);
}
