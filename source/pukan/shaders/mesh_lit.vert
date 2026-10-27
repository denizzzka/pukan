#version 460

layout(push_constant) uniform PushConsts
{
    mat4 trans;
};

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec3 color;
layout(location = 3) in vec2 vertTextureCoord;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec2 fragTextureCoord;
layout(location = 2) out vec3 fragNormal;

void main()
{
    fragColor = color;
    fragTextureCoord = vertTextureCoord;
    fragNormal = normal;

    gl_Position = trans * vec4(position, 1.0);
}
