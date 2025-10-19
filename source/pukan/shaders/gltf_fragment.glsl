#version 460

struct Material
{
    ivec4 renderType;
    vec4 baseColorFactor;
};

layout(binding = 0) uniform UniformBufferObject
{
    Material material;
} ubo;

layout(binding = 1) uniform sampler2D textureSampler;

layout(location = 0) in vec2 fragTextureCoord;
layout(location = 0) out vec4 outColor;

void main() {
    if(ubo.material.renderType.x == 1) // texture loaded
        outColor = texture(textureSampler, fragTextureCoord);
    else
        outColor = ubo.material.baseColorFactor;
        //~ outColor = vec4(0.5, 0.7, 0.2, 0.8);
}
