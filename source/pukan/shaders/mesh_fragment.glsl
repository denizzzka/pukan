#version 460

#include "material.glsl"

layout(binding = 0) uniform MaterialBlock
{
    Material material;
} ubo;

layout(binding = 1) uniform sampler2D baseColorTexture;

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec2 fragTextureCoord;

#ifdef HAS_NORMAL
layout(location = 2) in vec3 fragNormal;
#else
layout(location = 2) in vec3 fragPosition;
#endif

layout(location = 0) out vec4 outColor;

void main()
{
    const Material material = ubo.material;
    const vec3 albedo = materialAlbedo(material, fragColor, fragTextureCoord, baseColorTexture);

#ifdef HAS_NORMAL
    const vec3 normal = normalize(fragNormal);
#else
    const vec3 normal = normalize(cross(dFdx(fragPosition), dFdy(fragPosition)));
#endif

    outColor = vec4(shadeMaterial(material, albedo, normal), 1.0);
}
