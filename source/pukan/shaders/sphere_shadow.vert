#version 460

layout(push_constant) uniform Push
{
    mat4 mvp;
} pc;

layout(location = 0) in vec3 position;
layout(location = 1) in vec4 instance;

void main()
{
    const vec3 world = instance.xyz + position * instance.w;
    gl_Position = pc.mvp * vec4(world, 1.0);
}
