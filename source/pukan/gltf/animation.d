module pukan.gltf.animation;

import dlib.math;
import pukan.gltf: Node;
import pukan.pbr.accessor: BufAccess;
import pukan.gltf.loader;

/// Interpolation types supported by GLTF animation samplers
enum InterpolationType: string
{
    Undefined = "Undefined, error",
    LINEAR = "LINEAR",
    STEP = "STEP",
    CUBICSPLINE = "CUBICSPLINE"
}

/// Animation target property types (translation, rotation, scale)
enum TRSType: string
{
    translation = "translation",
    rotation = "rotation",
    scale = "scale",
}

/// Defines keyframe times, values, and interpolation
struct AnimationSampler
{
    ///
    InterpolationType interpolation;

    /// Accessor for keyframe times (in seconds)
    BufAccess inputAcc;

    /// Accessor for keyframe values
    BufAccess outputAcc;

    /**
     * Finds the keyframe sample indices and times for a given animation time.
     *
     * Params:
     *   t            = Current animation time.
     *   previousTime = Output: previous keyframe time.
     *   nextTime     = Output: next keyframe time.
     *   loopTime     = Output: wrapped time within the animation duration.
     * Returns:
     *   Index of the previous keyframe.
     */
    size_t getSampleByTime(GltfContent* content, in float currTime, out float previousTime, out float nextTime, out float loopTime) const
    {
        assert(inputAcc.viewIdx >= 0);

        auto timeline = content.rangify!float(inputAcc);
        assert(timeline.length > 1, "GLTF animation sampler input must have at least two keyframes");

        float duration = timeline[$ - 1];

        loopTime = currTime % duration;

        // Clamp to the input interval
        if (loopTime < timeline[0])
        {
            previousTime = timeline[0];
            nextTime = timeline[1];
            return 0;
        }
        if (loopTime >= timeline[$ - 1])
        {
            previousTime = timeline[$ - 2];
            nextTime = timeline[$ - 1];
            return timeline.length - 2;
        }

        foreach (i; 0..timeline.length - 1)
        {
            if (timeline[i] <= loopTime && loopTime < timeline[i + 1])
            {
                previousTime = timeline[i];
                nextTime = timeline[i + 1];
                return i;
            }
        }

        // Fallback
        previousTime = timeline[0];
        nextTime = timeline[1];
        return 0; // No translation found, so using first translation
    }
}

/// Represents a GLTF animation channel, which targets a node and property (TRS)
struct Channel
{
    /// The animation sampler for this channel
    uint samplerIdx;

    /// The property being animated (translation, rotation, scale)
    TRSType targetPath;

    /// The node being animated
    //~ Node targetNode;
    uint targetNode;
}

///
struct Animation
{
    /// Optional name
    string name;
    AnimationSampler[] samplers;
    Channel[] channels;
}

package struct AnimationSupport
{
    import pukan.gltf: Trans;

    private GltfContent* content;
    package Animation[] animations;
    package Trans[] perNodeTranslations;
    package float currTime = 0;

    package this(GltfContent* c, size_t nodesNum)
    {
        content = c;
        perNodeTranslations.length = nodesNum;
        animations = content.animations;
    }

    void setPose(const Animation* currAnimation, in Trans[] baseNodeTranslations)
    {
        assert(perNodeTranslations.length == baseNodeTranslations.length);
        perNodeTranslations[0..$] = baseNodeTranslations;

        foreach(const scope chan; currAnimation.channels)
        {
            const sampler = currAnimation.samplers[chan.samplerIdx];

            float prevTime;
            float nextTime;
            float loopTime;

            const prevIdx = sampler.getSampleByTime(content, currTime, prevTime, nextTime, loopTime);
            const nextIdx = prevIdx + 1;

            const float span = nextTime - prevTime;
            const float interpRatio = span > 0 ? (loopTime - prevTime) / span : 0;
            auto currTrans = &perNodeTranslations[chan.targetNode];

            if (chan.targetPath == TRSType.translation || chan.targetPath == TRSType.scale)
            {
                const output = content.rangify!Vector3f(sampler.outputAcc);

                const Vector3f value = sampler.interpolation == InterpolationType.STEP
                    ? output[prevIdx]
                    : (sampler.interpolation == InterpolationType.CUBICSPLINE
                        ? hermite(output[3 * prevIdx + 1], output[3 * nextIdx + 1],
                            output[3 * prevIdx + 2], output[3 * nextIdx], interpRatio, span)
                        : lerp(output[prevIdx], output[nextIdx], interpRatio));

                if (chan.targetPath == TRSType.translation)
                    currTrans.transl = value;
                else
                    currTrans.scale = value;
            }
            else if (chan.targetPath == TRSType.rotation)
            {
                const output = content.rangify!Quaternionf(sampler.outputAcc);

                const Quaternionf value = sampler.interpolation == InterpolationType.STEP
                    ? output[prevIdx]
                    : (sampler.interpolation == InterpolationType.CUBICSPLINE
                        ? hermite(output[3 * prevIdx + 1], output[3 * nextIdx + 1],
                            output[3 * prevIdx + 2], output[3 * nextIdx], interpRatio, span).normalized
                        : slerp(output[prevIdx], output[nextIdx], interpRatio));

                currTrans.rot = value;
            }
            else
                assert(0);
        }
    }

    /// Cubic Hermite curve; `span` is the time between the two keys.
    private static T hermite(T)(T fromValue, T toValue, T fromTangent, T toTangent, float t, float span)
    {
        const float t2 = t * t;
        const float t3 = t2 * t;

        return fromValue * (2 * t3 - 3 * t2 + 1)
            + fromTangent * (span * (t3 - 2 * t2 + t))
            + toValue * (-2 * t3 + 3 * t2)
            + toTangent * (span * (t3 - t2));
    }
}
