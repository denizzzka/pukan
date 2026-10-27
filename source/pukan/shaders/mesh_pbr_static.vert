#version 460

#include "frame.glsl"

layout(push_constant) uniform PushConsts
{
    mat4 trans;
};

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 vertTextureCoord;
layout(location = 2) in vec3 vertNormal;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec2 fragTextureCoord;
layout(location = 2) out vec3 fragNormal;
layout(location = 3) out vec3 fragPosition;

void main()
{
    fragColor = vec3(1.0);
    fragTextureCoord = vertTextureCoord;

    const mat4 model = frameUbo.frame.invViewProj * trans;
    const mat3 normalMatrix = transpose(inverse(mat3(model)));

    fragNormal = normalMatrix * vertNormal;
    fragPosition = (model * vec4(position, 1.0)).xyz;
    gl_Position = trans * vec4(position, 1.0);
}
