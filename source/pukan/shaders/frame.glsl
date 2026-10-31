const uint LIGHT_DIRECTIONAL = 0u;
const uint LIGHT_POINT = 1u;
const uint LIGHT_SPOT = 2u;

struct Light
{
    // Point and spot: xyz = world position, w = radius. Directional: xyz = direction to the light.
    vec4 positionRadius;
    vec4 directionOuterCos; // spot: xyz = beam direction, w = cosine of the outer angle
    vec4 colorIntensity;    // rgb = colour times intensity
    vec4 params;            // x = type, y = cosine of the inner angle
};

struct FrameData
{
    mat4 invViewProj;
    mat4 viewProj;
    mat4 shadowViewProj;
    vec4 cameraPosition;
    vec4 exposureParams; // x = exposure, y = IBL intensity, z = scene colour, w = light count
    vec4 shadowParams;   // x = 1 while the sun's shadow map is used
    vec4 ambientParams;  // rgb = ambient tint, a = ambient energy
    vec4 tonemapParams;  // x = mode, y = white
};

#include "frame_bindings.h"

layout(set = 1, binding = FRAME_UNIFORM) uniform FrameBlock
{
    FrameData frame;
} frameUbo;

layout(set = 1, binding = FRAME_LIGHTS) readonly buffer LightBuffer
{
    Light lights[];
};

/// The first light of the list is the sun
vec3 sunDirection()
{
    return normalize(lights[0].positionRadius.xyz);
}
