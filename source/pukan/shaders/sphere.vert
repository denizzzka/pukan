#version 460

#include "frame.glsl"

layout(push_constant) uniform Push {
    mat4 mvp;
} pc;

layout(set = 0, binding = 1) readonly buffer InstanceColors {
    uint instanceColors[];
};

layout(location = 0) in vec3 position;
layout(location = 1) in vec4 instance;

layout(location = 0) out vec3 normal;
layout(location = 1) flat out uint materialIndex;
layout(location = 2) out vec3 worldPosition;

void main()
{
    const vec3 world = instance.xyz + position * instance.w;
    const mat4 model = frameUbo.frame.invViewProj * pc.mvp;
    const mat3 normalMatrix = transpose(inverse(mat3(model)));

    gl_Position = pc.mvp * vec4(world, 1.0);

    normal = normalMatrix * position;
    materialIndex = instanceColors[gl_InstanceIndex];
    worldPosition = (model * vec4(world, 1.0)).xyz;
}
