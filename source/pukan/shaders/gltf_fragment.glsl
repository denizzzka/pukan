#version 460

struct Material {
    vec4 baseColorFactor;
};

layout(binding = 0) uniform UniformBufferObject {
    Material material;
} ubo;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = ubo.material.baseColorFactor;
}
