#version 450

layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
} ubo;

layout(push_constant) uniform PushConsts {
    mat4 transl;
} pushConsts;

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(location = 2) in vec2 textureCoord;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out vec2 fragTextureCoord;

void main() {
    gl_Position = ubo.proj * ubo.view * ubo.model * pushConsts.transl * vec4(position, 1.0);
    fragColor = color;
    fragTextureCoord = textureCoord;
}
