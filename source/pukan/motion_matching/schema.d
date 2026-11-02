module pukan.motion_matching.schema;

/// Time step used to measure velocities as a finite difference:
/// `(position(time) - position(time - step)) / step`.
///
/// Indexing and querying must use the same value, otherwise their velocities are not
/// comparable at all. The rate at which the animation is updated has nothing to do with
/// it: this is a measurement step, not a tick.
enum DerivativeStep: float
{
    /// A sixtieth of a second, fine enough to stay local and coarse enough to not amplify noise.
    sixtyHz = 1.0f / 60.0f,
}

/// A bone that takes part in a match, with the parts of its motion that matter.
struct BoneChannel
{
    string bone;
    bool position = true;
    bool velocity = true;
    /// Multiplier for the squared difference of this bone's values.
    float weight = 1;
}

/// A point on the trajectory, `offset` seconds away from now.
struct TrajectoryChannel
{
    /// Seconds from now: negative is history, positive is the prediction.
    float offset;
    bool position = true;
    bool velocity = true;
    bool heading = true;
    /// Multiplier for the squared difference of this point's values.
    float weight = 1;
}

/// What a match compares, and how much each part of it weighs.
///
/// The channel vector of one pose is a flat float array laid out in the order of `trajectory`
/// and then `bones`, so the database and the query are built by the same code.
struct Schema
{
    /// Bone the other bones are measured from; empty means the root of the skeleton.
    string rootBone;
    /// Database sampling rate, in poses per second.
    int sampleRate = 30;
    DerivativeStep derivativeStep = DerivativeStep.sixtyHz;
    TrajectoryChannel[] trajectory;
    BoneChannel[] bones;

    /// Number of floats in one channel vector.
    uint dimensions() const
    {
        uint result;

        foreach(ref channel; trajectory)
        {
            if(channel.position)
                result += 3;
            if(channel.velocity)
                result += 3;
            if(channel.heading)
                result += 2;
        }

        foreach(ref channel; bones)
        {
            if(channel.position)
                result += 3;
            if(channel.velocity)
                result += 3;
        }

        return result;
    }

    /// One multiplier per dimension, applied to squared differences.
    float[] weights() const
    {
        float[] result;
        result.reserve(dimensions);

        foreach(ref channel; trajectory)
        {
            if(channel.position)
                addRepeated(result, channel.weight, 3);
            if(channel.velocity)
                addRepeated(result, channel.weight, 3);
            if(channel.heading)
                addRepeated(result, channel.weight, 2);
        }

        foreach(ref channel; bones)
        {
            if(channel.position)
                addRepeated(result, channel.weight, 3);
            if(channel.velocity)
                addRepeated(result, channel.weight, 3);
        }

        return result;
    }

    /// A first layout for locomotion: the feet and the hands carry the gait, the pelvis and
    /// the head the posture; the trajectory is the four points Unreal ships by default.
    static Schema locomotion()
    {
        Schema result;

        result.trajectory = [
            TrajectoryChannel(-0.4, true, false, false, 7),
            TrajectoryChannel(0, false, true, true, 7),
            TrajectoryChannel(0.35, true, false, true, 7),
            TrajectoryChannel(0.7, true, true, true, 7),
        ];

        result.bones = [
            BoneChannel("foot_l"),
            BoneChannel("foot_r"),
            BoneChannel("hand_l"),
            BoneChannel("hand_r"),
            BoneChannel("pelvis"),
            BoneChannel("head"),
        ];

        return result;
    }
}

private void addRepeated(ref float[] values, float value, size_t count)
{
    foreach(i; 0 .. count)
        values ~= value;
}
unittest
{
    // A trajectory point with position, velocity and heading is 8 floats, a bone with
    // position and velocity is 6
    Schema schema;
    schema.trajectory = [TrajectoryChannel(0.35, true, true, true, 2)];
    schema.bones = [BoneChannel("foot_l", true, true, 3)];

    assert(schema.dimensions == 14);

    const weights = schema.weights;
    assert(weights.length == 14);
    assert(weights[0] == 2 && weights[7] == 2);
    assert(weights[8] == 3 && weights[13] == 3);
}

unittest
{
    const schema = Schema.locomotion;

    // 21 trajectory floats and 6 bones of 6 floats
    assert(schema.dimensions == 57);
    assert(schema.weights.length == 57);
    // The member is a compile-time constant, the field is a float: compare as floats
    assert(cast(float) schema.derivativeStep == cast(float) DerivativeStep.sixtyHz);
}
