module pukan.gltf.animation;

import pukan.gltf.accessor: BufAccess;
import pukan.gltf: Node;

/// Interpolation types supported by GLTF animation samplers
enum InterpolationType: string
{
    Linear = "LINEAR",
    Step = "STEP",
    CubicSpline = "CUBICSPLINE"
}

/// Animation target property types (translation, rotation, scale)
enum TRSType: string
{
    Translation = "translation",
    Rotation = "rotation",
    Scale = "scale",
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
    AnimationSampler sampler;

    /// The property being animated (translation, rotation, scale)
    TRSType targetPath;

    /// The node being animated
    Node targetNode;
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
}
