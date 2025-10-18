#version 460

struct Material
{
    uint renderType;
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
    //~ if(ubo.material.renderType == 1) // texture loaded
        outColor = vec4(1.0, 0.0, 1.0, 1.0);
        //~ outColor = texture(textureSampler, fragTextureCoord);
    //~ else
        //~ outColor = vec4(1,1,0,0.5);
        //~ outColor = ubo.material.baseColorFactor;
}
