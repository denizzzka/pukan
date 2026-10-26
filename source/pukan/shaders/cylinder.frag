#version 460

#include "shade.glsl"

layout(location = 0) in vec3 normal;
layout(location = 1) flat in vec3 instanceColor;
layout(location = 2) flat in uint instanceFlags;

layout(location = 0) out vec4 outColor;

void main()
{
    outColor = vec4(shadeSurface(normal, instanceColor, instanceFlags), 1.0);
}
