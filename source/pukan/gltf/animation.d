module pukan.gltf.animation;

import pukan.gltf.accessor: BufAccess;
import pukan.gltf: Node;

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
    size_t getSampleByTime(in float t, out float previousTime, out float nextTime, out float loopTime)
    {
        assert(inputAcc.viewIdx >= 0);

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
    import pukan.gltf.loader;

    private GltfContent* content;

    import dlib.math;

    Matrix4x4f[] perNodeTranslations;

    package this(GltfContent* c, size_t nodesNum)
    {
        content = c;
        perNodeTranslations.length = nodesNum;
    }
}
