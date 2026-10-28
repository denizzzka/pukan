#version 460

#include "frame.glsl"
#include "material_bindings.h"

layout(push_constant) uniform PushConsts
{
    mat4 trans;
};

layout(binding = MATERIAL_JOINTS) readonly buffer JointMatrices
{
    mat4 jointMatrices[];
};

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 vertTextureCoord;
layout(location = 2) in uvec4 jointIndices;
layout(location = 3) in vec4 weight;
layout(location = 4) in vec3 vertNormal;
layout(location = 5) in vec4 vertTangent;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec2 fragTextureCoord;
layout(location = 2) out vec3 fragNormal;
layout(location = 3) out vec3 fragPosition;
layout(location = 4) out vec4 fragTangent;

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
    const mat3 model3 = mat3(model);
    const mat3 skin3 = mat3(skinMatrix);
    const mat3 normalMatrix = transpose(inverse(model3));

    fragPosition = (model * positionOut).xyz;
    fragNormal = normalMatrix * (skin3 * vertNormal);
    fragTangent = vec4(model3 * (skin3 * vertTangent.xyz), vertTangent.w * sign(determinant(model3 * skin3)));
    gl_Position = trans * positionOut;
}
