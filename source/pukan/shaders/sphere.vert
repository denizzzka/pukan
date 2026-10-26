#version 460

#include "shade.glsl"

layout(push_constant) uniform Push {
    mat4 mvp;
} pc;

layout(set = 0, binding = 0) uniform Palette {
    vec4 colors[16];
} palette;

layout(set = 0, binding = 1) readonly buffer InstanceColors {
    uint instanceColors[];
};

layout(location = 0) in vec3 position;
layout(location = 1) in vec4 instance;

layout(location = 0) out vec3 normalOut;
layout(location = 1) flat out vec3 instanceColor;
layout(location = 2) flat out uint instanceFlags;

void main()
{
    const vec3 world = instance.xyz + position * instance.w;
    gl_Position = pc.mvp * vec4(world, 1.0);

    const vec4 group = palette.colors[instanceColors[gl_InstanceIndex]];

    normalOut = position;
    instanceColor = group.rgb;
    instanceFlags = uint(group.w);
}
