const uint LIGHT_DIRECTIONAL = 0u;
const uint LIGHT_POINT = 1u;
const uint LIGHT_SPOT = 2u;

struct Light
{
    // Point and spot: xyz = world position, w = radius. Directional: xyz = direction to the light.
    vec4 positionRadius;
    vec4 directionOuterCos; // spot: xyz = beam direction, w = cosine of the outer angle
    vec4 colorIntensity;    // rgb = colour times intensity
    vec4 params;            // x = type, y = cosine of the inner angle, z = shadow tile, w = bias
    mat4 shadowViewProj[6]; // spot: face 0; point: the six cube faces
};

struct FrameData
{
    mat4 invViewProj;
    mat4 viewProj;
    mat4 shadowViewProj[3];
    vec4 cameraPosition;
    vec4 exposureParams; // x = exposure, y = IBL intensity, z = scene colour, w = light count
    vec4 shadowParams;   // x = 1 while the sun's shadow map is used, yzw = depth bias per cascade
    vec4 shadowSplits;   // xyz = far view depth of each cascade
    vec4 localShadowParams; // x = 1/tiles, y = tiles, z = 1/tile size
    vec4 ambientParams;  // rgb = ambient tint, a = ambient energy
    vec4 tonemapParams;  // x = mode, y = white
    vec4 fogParams;      // x = 1 while the fog runs, y = density, z = anisotropy, w = length
    vec4 fogAlbedo;      // rgb = albedo, a = emission energy
    vec4 fogEmission;    // rgb = emission colour, a = sky affect
    vec4 fogDepth;       // x = near, y = far, z = log2 near, w = 1/(log2 far - log2 near)
    vec4 fogScreen;      // xy = 1/target size, zw = target size
    vec4 heightFogParams; // x = enabled, y = density, z = base height, w = falloff per metre
    vec4 heightFogColor;  // rgb = the light the layer adds
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
