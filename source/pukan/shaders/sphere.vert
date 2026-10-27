#version 460

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

void main()
{
    const vec3 world = instance.xyz + position * instance.w;
    gl_Position = pc.mvp * vec4(world, 1.0);

    normal = position;
    materialIndex = instanceColors[gl_InstanceIndex];
}
