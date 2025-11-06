module pukan.gltf.animation;

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
    private GltfContent* content;
    private Animation[] animations;

    import dlib.math;

    Matrix4x4f[] perNodeTranslations;

    package this(GltfContent* c, size_t nodesNum)
    {
        content = c;
        perNodeTranslations.length = nodesNum;
        animations = content.animations;
    }

    Matrix4x4f[] calculatePose(const Animation* currAnimation, float currTime)
    {
        Matrix4x4f[] translations;
        translations.length = perNodeTranslations.length;

        foreach(ref e; translations)
        {
            // Negative scale to avoid mirroring when loaded OpenGL mesh into Vulkan
            e = Matrix4x4f.identity * Vector3f(-1, -1, -1).scaleMatrix;
        }

        foreach(chan; currAnimation.channels)
        {
            float prevTime = 0.0f;
            float nextTime = 0.0f;
            float loopTime = 0.0f;

            const sampler = currAnimation.samplers[chan.samplerIdx];
            const prevIdx = sampler.getSampleByTime(content, currTime, prevTime, nextTime, loopTime);

            import std.stdio;
            writeln(sampler);
            writeln(prevIdx);
            writeln(loopTime);
            writeln(prevTime);
            writeln(nextTime);
        }

        return translations;
    }
}
