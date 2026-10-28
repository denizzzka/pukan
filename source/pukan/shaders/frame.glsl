struct PointLight
{
    vec4 positionRadius; // xyz = world position, w = radius
    vec4 color;          // rgb = colour
};

struct FrameData
{
    mat4 invViewProj;
    vec4 cameraPosition;
    vec4 lightDirection;
    vec4 lightColor;
    vec4 exposureParams; // x = exposure, y = IBL intensity, z = scene colour, w = point light count
    PointLight pointLights[8];
};

#include "frame_bindings.h"

layout(set = 1, binding = FRAME_UNIFORM) uniform FrameBlock
{
    FrameData frame;
} frameUbo;
