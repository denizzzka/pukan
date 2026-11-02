module pukan.motion_matching.database;

import dlib.math: Vector3f;
import pukan.axes: Axis, planeComponents;
import pukan.motion_matching.schema: Schema;
import pukan.motion_matching.transform: Transform;
import std.algorithm: min;
import std.exception: enforce;

/// An animation clip, as far as indexing is concerned.
struct Clip
{
    string name;
    /// Seconds.
    float duration;
    /// Whether the clip returns to its first pose at the end.
    bool looping = true;
}

/// A pose read from a clip: where the root is, and where the bones are measured from it.
struct ClipPose
{
    Transform root;
    /// One position per `Schema.bones`, in the root's space of the clip.
    Vector3f[] bones;
}

/// Reads a clip at any time, wrapping or clamping that time to the clip itself.
alias ClipSampler = ClipPose delegate(size_t clipIndex, float time);

/// Marks a sample index that points at nothing.
enum size_t invalidSample = size_t.max;

/// Where the samples of one clip start and how many there are.
struct ClipRange
{
    size_t first;
    size_t count;
}

/// One indexed pose.
struct Sample
{
    ushort clip;
    /// Seconds from the start of the clip.
    float time;
    /// Added to the distance, so a pose or a whole clip can be made less likely to be picked.
    float bias;
}

/// Channel vectors of a clip set, laid out by a `Schema`.
///
/// The whole table is built once, ahead of the search; a search itself only reads it.
struct Database
{
    Schema schema;
    Axis up;
    Clip[] clips;
    ClipRange[] ranges;
    Sample[] samples;
    /// `samples.length * schema.dimensions()` floats.
    float[] vectors;
    /// One multiplier per dimension, applied to squared differences.
    float[] dimensionWeights;
    /// Added to every sample.
    float baseBias = 0;
    /// Added to the samples of looping clips, since they can repeat themselves.
    float loopBias = 0;
    /// Added to the distance of the pose that is already playing: the bias for not
    /// interrupting it.
    float keepPlayingBias = 0;

    /// Indexes `clips`. The sampler is asked for times outside a clip as well, to measure
    /// velocities and the trajectory points at the ends, so it must wrap or clamp them.
    void build(Sampler)(Schema schema, Axis up, const(Clip)[] clips, Sampler sampler)
    {
        static assert(is(typeof(sampler(size_t(0), 0.0f)) == ClipPose),
            "the sampler must take a clip index and a time and return a ClipPose");

        enforce(schema.dimensions > 0, "schema has no channels");

        this.schema = schema;
        this.up = up;
        this.clips = clips.dup;
        this.ranges.length = clips.length;
        dimensionWeights = schema.weights;

        const dimensions = schema.dimensions;
        const float step = schema.derivativeStep;

        size_t count;
        foreach(ref clip; clips)
            count += sampleSteps(clip, schema.sampleRate) + 1;

        samples.length = count;
        vectors.length = count * dimensions;

        size_t sampleIdx;
        size_t valueIdx;

        foreach(clipIdx, ref clip; clips)
        {
            const size_t steps = sampleSteps(clip, schema.sampleRate);

            ranges[clipIdx] = ClipRange(sampleIdx, steps + 1);

            foreach(i; 0 .. steps + 1)
            {
                const float time = min(i / cast(float) schema.sampleRate, clip.duration);

                samples[sampleIdx] = Sample(
                    cast(ushort) clipIdx,
                    time,
                    baseBias + (clip.looping ? loopBias : 0),
                );
                ++sampleIdx;

                const pose = sampler(clipIdx, time);
                const now = pose.root;

                foreach(ref channel; schema.trajectory)
                {
                    const at = sampler(clipIdx, time + channel.offset).root;
                    const position = now.applyInverse(up, at.translation);

                    if(channel.position)
                        putPosition(vectors, valueIdx, position);

                    if(channel.velocity)
                    {
                        const before = sampler(clipIdx, time + channel.offset - step).root;
                        const positionBefore = now.applyInverse(up, before.translation);
                        putPosition(vectors, valueIdx, (position - positionBefore) / step);
                    }

                    if(channel.heading)
                    {
                        const heading = now.rotateInverse(up, at.forward(up));
                        const plane = up.planeComponents(heading);
                        vectors[valueIdx] = plane[0];
                        vectors[valueIdx + 1] = plane[1];
                        valueIdx += 2;
                    }
                }

                if(schema.bones.length > 0)
                {
                    enforce(pose.bones.length == schema.bones.length, "the pose has no position for every bone of the schema");

                    const poseBefore = sampler(clipIdx, time - step);
                    enforce(poseBefore.bones.length == pose.bones.length, "the pose before has a different bone count");

                    foreach(boneIdx, ref channel; schema.bones)
                    {
                        if(channel.position)
                            putPosition(vectors, valueIdx, pose.bones[boneIdx]);

                        if(channel.velocity)
                            putPosition(vectors, valueIdx, (pose.bones[boneIdx] - poseBefore.bones[boneIdx]) / step);
                    }
                }
            }
        }
    }

    /// Index of the sample nearest to `time` inside `clip`: a looping clip wraps the time,
    /// the others clamp it. `invalidSample` when the clip has no samples at all.
    size_t sampleIndex(size_t clip, float time) const
    {
        if(clip >= ranges.length)
            return invalidSample;

        const range = ranges[clip];

        if(range.count == 0)
            return invalidSample;

        const source = clips[clip];
        float local = time;

        if(source.duration > 0 && source.looping)
        {
            local %= source.duration;

            if(local < 0)
                local += source.duration;
        }
        else
            local = local < 0 ? 0 : (local > source.duration ? source.duration : local);

        size_t offset = cast(size_t) (local * schema.sampleRate + 0.5f);

        if(offset >= range.count)
            offset = range.count - 1;

        return range.first + offset;
    }

    /// Weighted squared distance between a stored pose and a query vector.
    float distance(size_t sampleIdx, const(float)[] query) const
    {
        assert(query.length == dimensionWeights.length);

        const start = sampleIdx * dimensionWeights.length;

        float result = 0;

        foreach(i, weight; dimensionWeights)
        {
            const difference = query[i] - vectors[start + i];
            result += weight * difference * difference;
        }

        return result;
    }
}

/// Number of whole sampling steps a clip holds.
private size_t sampleSteps(Clip clip, int sampleRate)
{
    return cast(size_t)(clip.duration * sampleRate);
}

package void putPosition(ref float[] values, ref size_t index, Vector3f position)
{
    values[index] = position.x;
    values[index + 1] = position.y;
    values[index + 2] = position.z;
    index += 3;
}

unittest
{
    import pukan.motion_matching.schema: BoneChannel, TrajectoryChannel;
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
    schema.trajectory = [TrajectoryChannel(0.35, true, true, true, 1)];

    assert(schema.dimensions == 14);

    Database database;
    database.build(schema, up, [Clip("walk", 2)], &sampleStraightLine);

    // Two seconds at 30 Hz, both ends included
    assert(database.samples.length == 61);
    assert(database.vectors.length == 61 * 14);

    size_t second = size_t.max;
    foreach(i, ref sample; database.samples)
        if(sample.time == 1)
            second = i;

    assert(second != size_t.max);

    const vector = database.vectors[second * 14 .. (second + 1) * 14];

    // A point 0.35 s ahead is 0.7 m ahead while the root stands at 2 m
    assert(vector[0] == 0 && vector[1] == 0);
    assert(abs(vector[2] - 0.7f) < 1e-5);

    // Its speed is exactly the speed of the root
    assert(abs(vector[3]) < 1e-5 && abs(vector[4]) < 1e-5);
    assert(abs(vector[5] - 2) < 1e-4);

    // The heading is forward: (x, z) = (0, 1)
    assert(abs(vector[6]) < 1e-5);
    assert(abs(vector[7] - 1) < 1e-5);

    // The bone sits 0.1 + 0.05 * sin(3) above the root and follows it
    const boneHeight = 0.1f + 0.05f * sin(3.0f);
    assert(abs(vector[9] - boneHeight) < 1e-5);

    // The same vector as a query is at zero distance
    assert(database.distance(second, vector) == 0);

    // A query one metre aside is not
    float[] far = vector.dup;
    far[0] = 1;
    assert(database.distance(second, far) > 0);
}

unittest
{
    import pukan.motion_matching.schema: BoneChannel;

    enum up = Axis.y;

    static ClipPose sampleStill(size_t clip, float time)
    {
        ClipPose result;
        result.root = Transform.identity;
        result.bones = [Vector3f(0, 0, 0)];
        return result;
    }

    Schema schema;
    schema.bones = [BoneChannel("foot")];

    Database database;
    database.baseBias = 0.5f;
    database.loopBias = 0.25f;
    database.build(schema, up, [Clip("idle", 1), Clip("turn", 1, false)], &sampleStill);

    assert(database.samples.length == 62);
    assert(database.samples[0].bias == 0.75f);
    assert(database.samples[$ - 1].bias == 0.5f);
}
