#version 460

#include "material.glsl"

layout(set = 0, binding = 0) uniform Palette {
    Material materials[16];
} palette;

layout(set = 0, binding = 2) uniform sampler2D baseColorTexture;

layout(location = 0) in vec3 normal;
layout(location = 1) flat in uint materialIndex;

layout(location = 0) out vec4 outColor;

void main()
{
    const Material material = palette.materials[materialIndex];
    const vec3 albedo = materialAlbedo(material, vec3(1.0), vec2(0.0), baseColorTexture);

    outColor = vec4(shadeMaterial(material, albedo, normal), 1.0);
}
