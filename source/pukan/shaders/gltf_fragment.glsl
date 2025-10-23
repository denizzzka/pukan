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
    {
        //~ if(fragTextureCoord.x < 0 || fragTextureCoord.y < 0)
            //~ outColor = ubo.material.baseColorFactor;
        //~ else if(fragTextureCoord.x > 1 || fragTextureCoord.y > 1)
            //~ outColor = vec4(0.59, 0.49, 1, 1.0);
        //~ else
            outColor = texture(textureSampler, fragTextureCoord);

            if((fragTextureCoord.x + fragTextureCoord.y)/2 < 0.1)
                outColor = ubo.material.baseColorFactor;
    }
    else
        outColor = ubo.material.baseColorFactor;
}
