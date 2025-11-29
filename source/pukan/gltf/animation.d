module pukan.gltf.animation;

import dlib.math;
import pukan.gltf: Node;
import pukan.gltf.accessor: BufAccess;
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
            assert(sampler.interpolation == InterpolationType.LINEAR, "TODO: support all interpolation types");

            float prevTime;
            float nextTime;
            float loopTime;

            const prevIdx = sampler.getSampleByTime(content, currTime, prevTime, nextTime, loopTime);
            const nextIdx = prevIdx + 1;

            const float interpRatio = (loopTime - prevTime) / (nextTime - prevTime);
            auto currTrans = &perNodeTranslations[chan.targetNode];

            if (chan.targetPath == TRSType.translation)
            {
                const output = content.rangify!Vector3f(sampler.outputAcc);
                const Vector3f prevTrans = output[prevIdx];
                const Vector3f nextTrans = output[nextIdx];
                currTrans.transl = lerp(prevTrans, nextTrans, interpRatio);
            }
            else if (chan.targetPath == TRSType.rotation)
            {
                const output = content.rangify!Quaternionf(sampler.outputAcc);
                const Quaternionf prevRot = output[prevIdx];
                const Quaternionf nextRot = output[nextIdx];
                // slerp: spherical linear interpolation:
                currTrans.rot = slerp(prevRot, nextRot, interpRatio);
            }
            else if (chan.targetPath == TRSType.scale)
            {
                const output = content.rangify!Vector3f(sampler.outputAcc);
                const Vector3f prevScale = output[prevIdx];
                const Vector3f nextScale = output[nextIdx];

                currTrans.scale = lerp(prevScale, nextScale, interpRatio);
            }
            else
                assert(0);
        }
    }
}
