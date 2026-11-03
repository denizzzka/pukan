module pukan.vulkan.frame_bindings;

/// Binding indices of the frame descriptor set, supplied by the application
struct FrameBindings
{
    // A binding left out stays unset and fails the layout instead of aliasing 0
    uint uniform = uint.max;
    uint irradiance = uint.max;
    uint prefiltered = uint.max;
    uint brdfLut = uint.max;
    uint sceneColor = uint.max;
    uint oitHeads = uint.max;
    uint oitFragments = uint.max;
    uint oitCounter = uint.max;
    uint lights = uint.max;
    uint shadowMap = uint.max;
    uint sceneDepth = uint.max;
    uint depthMS = uint.max;
}
