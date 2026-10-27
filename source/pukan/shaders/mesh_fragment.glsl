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

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec2 fragTextureCoord;

layout(location = 0) out vec4 outColor;

void main()
{
    if(ubo.material.renderType.x == 0)
        outColor = vec4(fragColor, 1.0);
    else if(ubo.material.renderType.x == 1)
        outColor = texture(textureSampler, fragTextureCoord);
    else
        outColor = ubo.material.baseColorFactor;
}
