#version 460

#include "frame_bindings.h"

layout(set = 1, binding = FRAME_DEPTH_MS) uniform sampler2DMS depthMS;

layout(location = 0) out float nearestDepth;

void main()
{
    const ivec2 pixel = ivec2(gl_FragCoord.xy);
    const int samples = textureSamples(depthMS);

    float nearest = 1.0;

    for(int i = 0; i < samples; ++i)
        nearest = min(nearest, texelFetch(depthMS, pixel, i).r);

    nearestDepth = nearest;
}
