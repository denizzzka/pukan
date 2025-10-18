#version 460

layout(push_constant) uniform PushConsts
{
    mat4 transl;
} pushConsts;

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 vertTextureCoord;

layout(location = 0) out vec2 fragTextureCoord;

void main()
{
    fragTextureCoord = vertTextureCoord;
    gl_Position = pushConsts.transl * vec4(position, 1.0);
}
