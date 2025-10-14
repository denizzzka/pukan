#version 450

struct Material {
    vec4 baseColorFactor;
};

layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
    Material material;
} ubo;

layout(push_constant) uniform PushConsts {
    mat4 transl;
} pushConsts;

layout(location = 0) in vec3 position;

layout(location = 0) out vec4 fragColor;

void main() {
    gl_Position = ubo.proj * ubo.view * ubo.model * pushConsts.transl * vec4(position, 1.0);
    fragColor = ubo.material.baseColorFactor;
}
