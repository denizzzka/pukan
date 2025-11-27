#version 460

layout(binding = 2) readonly buffer JointMatrices
{
    mat4 jointMatrices[];
};

layout(push_constant) uniform PushConsts
{
    mat4 trans;
};

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 vertTextureCoord;
layout(location = 2) in uvec4 jointIndices; // four indices of the joints that should have an influence on the vertex during the skinning process
layout(location = 3) in vec4 weight;

layout(location = 0) out vec2 fragTextureCoord;

void main()
{
    fragTextureCoord = vertTextureCoord;

    //~ const mat4 skinMatrix =
        //~ weight.x * jointMatrices[jointIndices.x] +
        //~ weight.y * jointMatrices[jointIndices.y] +
        //~ weight.z * jointMatrices[jointIndices.z] +
        //~ weight.w * jointMatrices[jointIndices.w];

    //~ gl_Position = trans * skinMatrix * vec4(position, 1.0);
    gl_Position = trans * vec4(position, 1.0);
}
