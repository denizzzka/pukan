#version 460

#include "material.glsl"
#include "material_bindings.h"

layout(binding = MATERIAL_UNIFORM) uniform MaterialBlock
{
    Material material;
} ubo;

layout(binding = MATERIAL_BASE_COLOR) uniform sampler2D baseColorTexture;

layout(location = 1) in vec2 fragTextureCoord;

// Depth-only casters cut out the same texels the forward masked pass does
void main()
{
    vec2 uv = fragTextureCoord;
#ifdef GODOT_MATERIAL
    uv = uv * ubo.material.uvTransform.xy + ubo.material.uvTransform.zw;
#endif

    const vec4 base = materialBaseColor(ubo.material, vec3(1.0), uv, baseColorTexture);

    if(base.a < ubo.material.alphaParams.x)
        discard;
}
