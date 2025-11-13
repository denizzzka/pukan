#version 460

layout(binding = 2) uniform UniformBufferObject
{
    mat4 jointMatrices[777]; //FIXME
} ubo;

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

    const mat4 skinned =
        weight.x * ubo.jointMatrices[jointIndices.x] +
        weight.y * ubo.jointMatrices[jointIndices.y] +
        weight.z * ubo.jointMatrices[jointIndices.z] +
        weight.w * ubo.jointMatrices[jointIndices.w];

    gl_Position = skinned * pushConsts.transl * vec4(position, 1.0);
}
