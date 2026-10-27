#version 460

#include "frame.glsl"

layout(push_constant) uniform PushConsts
{
    mat4 trans;
};

#ifdef SKINNED
layout(binding = 2) readonly buffer JointMatrices
{
    mat4 jointMatrices[];
};

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 vertTextureCoord;
layout(location = 2) in uvec4 jointIndices;
layout(location = 3) in vec4 weight;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec2 fragTextureCoord;
layout(location = 2) out vec3 fragPosition;

void main()
{
    fragColor = vec3(1.0);
    fragTextureCoord = vertTextureCoord;

    const mat4 skinMatrix =
        jointMatrices[jointIndices.x] * weight.x +
        jointMatrices[jointIndices.y] * weight.y +
        jointMatrices[jointIndices.z] * weight.z +
        jointMatrices[jointIndices.w] * weight.w;

    const vec4 positionOut = skinMatrix * vec4(position, 1.0);
    const mat4 model = frameUbo.frame.invViewProj * trans;

    fragPosition = (model * positionOut).xyz;
    gl_Position = trans * positionOut;
}
#else
layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(location = 2) in vec2 vertTextureCoord;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec2 fragTextureCoord;
layout(location = 2) out vec3 fragPosition;

void main()
{
    fragColor = color;
    fragTextureCoord = vertTextureCoord;

    const mat4 model = frameUbo.frame.invViewProj * trans;

    fragPosition = (model * vec4(position, 1.0)).xyz;
    gl_Position = trans * vec4(position, 1.0);
}
#endif
