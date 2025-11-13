#version 460

layout(push_constant) uniform PushConsts
{
    mat4 transl;
} pushConsts;

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 vertTextureCoord;
layout(location = 2) in uvec4 jointIndices; // four indices of the joints that should have an influence on the vertex during the skinning process
layout(location = 3) in vec4 weight;

layout(location = 0) out vec2 fragTextureCoord;

void main()
{
    fragTextureCoord = vertTextureCoord;
    gl_Position = pushConsts.transl * vec4(position, 1.0);
}
