struct FrameData
{
    mat4 invViewProj;
    vec4 cameraPosition;
    vec4 lightDirection;
    vec4 lightColor;
    vec4 exposureParams; // x = exposure, y = IBL intensity
};

#include "frame_bindings.h"

layout(set = 1, binding = FRAME_UNIFORM) uniform FrameBlock
{
    FrameData frame;
} frameUbo;
