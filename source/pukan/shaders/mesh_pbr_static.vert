#version 460

#include "frame.glsl"

layout(push_constant) uniform PushConsts
{
    mat4 trans;
};

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 vertTextureCoord;
layout(location = 2) in vec3 vertNormal;
layout(location = 3) in vec4 vertTangent;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec2 fragTextureCoord;
layout(location = 2) out vec3 fragNormal;
layout(location = 3) out vec3 fragPosition;
layout(location = 4) out vec4 fragTangent;

void main()
{
#ifdef SHADOW
    gl_Position = trans * vec4(position, 1.0);
    return;
#endif

    fragColor = vec3(1.0);
    fragTextureCoord = vertTextureCoord;

    const mat4 model = frameUbo.frame.invViewProj * trans;
    const mat3 model3 = mat3(model);
    const mat3 normalMatrix = transpose(inverse(model3));

    fragNormal = normalMatrix * vertNormal;
    fragTangent = vec4(model3 * vertTangent.xyz, vertTangent.w * sign(determinant(model3)));
    fragPosition = (model * vec4(position, 1.0)).xyz;
    gl_Position = trans * vec4(position, 1.0);
}
