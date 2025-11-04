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
    BufAccess input;

    /// Accessor for keyframe values
    BufAccess output;
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

package mixin template GltfAnimation()
{
    private Matrix4x4f[] perNodeTranslations;
}
