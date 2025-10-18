#version 460

struct Material
{
    vec4 baseColorFactor;
};

//TODO: unused, use if texture not loaded
layout(binding = 0) uniform UniformBufferObject
{
    Material material;
} ubo;

layout(binding = 1) uniform sampler2D textureSampler;

layout(location = 0) in vec2 fragTextureCoord;
layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(textureSampler, fragTextureCoord);
}
