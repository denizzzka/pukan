#version 460

layout(push_constant) uniform Push
{
    mat4 mvp;
} pc;

layout(location = 0) in vec3 position;

void main()
{
    gl_Position = pc.mvp * vec4(position, 1.0);
}
