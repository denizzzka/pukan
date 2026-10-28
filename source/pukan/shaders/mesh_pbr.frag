#version 460

#include "material.glsl"

layout(binding = 0) uniform MaterialBlock
{
    Material material;
} ubo;

layout(binding = 1) uniform sampler2D baseColorTexture;
layout(binding = 3) uniform sampler2D metallicRoughnessTexture;
layout(binding = 4) uniform sampler2D normalTexture;
layout(binding = 5) uniform sampler2D occlusionTexture;
layout(binding = 6) uniform sampler2D emissiveTexture;
layout(binding = 7) uniform sampler2D specularTexture;
layout(binding = 8) uniform sampler2D specularColorTexture;
layout(binding = 9) uniform sampler2D clearcoatTexture;
layout(binding = 10) uniform sampler2D clearcoatRoughnessTexture;
layout(binding = 11) uniform sampler2D clearcoatNormalTexture;
layout(binding = 12) uniform sampler2D sheenColorTexture;
layout(binding = 13) uniform sampler2D sheenRoughnessTexture;
layout(binding = 14) uniform sampler2D anisotropyTexture;

layout(location = 0) in vec3 fragColor;
layout(location = 1) in vec2 fragTextureCoord;
layout(location = 2) in vec3 fragNormal;
layout(location = 3) in vec3 fragPosition;
layout(location = 4) in vec4 fragTangent;

layout(location = 0) out vec4 outColor;

vec3 perturbNormalFromDerivatives(sampler2D normalMap, float scale, vec3 normal, vec3 position, vec2 uv)
{
    const vec3 sampled = texture(normalMap, uv).xyz * 2.0 - 1.0;
    const vec3 mapNormal = vec3(sampled.xy * scale, sampled.z);

    const vec3 dp1 = dFdx(position);
    const vec3 dp2 = dFdy(position);
    const vec2 duv1 = dFdx(uv);
    const vec2 duv2 = dFdy(uv);

    const vec3 dp2perp = cross(dp2, normal);
    const vec3 dp1perp = cross(normal, dp1);
    const vec3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    const vec3 B = dp2perp * duv1.y + dp1perp * duv2.y;

    const mat3 TBN = mat3(normalize(T), normalize(B), normalize(normal));

    return normalize(TBN * mapNormal);
}

vec3 perturbNormalFromTangent(sampler2D normalMap, float scale, vec3 normal, vec3 position, vec2 uv, vec4 tangent)
{
    const vec3 N = normalize(normal);
    const vec3 T = tangent.xyz - N * dot(N, tangent.xyz);
    const vec3 B = cross(N, T) * (tangent.w < 0.0 ? -1.0 : 1.0);

    // Geometry derivatives stay continuous across UV seams, so they survive
    // where the texture coordinate derivative flips.
    const vec2 uvDx = vec2(
        dot(dFdx(position), T) / dot(T, T),
        dot(dFdx(position), B) / dot(B, B)
    );
    const vec2 uvDy = vec2(
        dot(dFdy(position), T) / dot(T, T),
        dot(dFdy(position), B) / dot(B, B)
    );

    const vec3 sampled = textureGrad(normalMap, uv, uvDx, uvDy).xyz * 2.0 - 1.0;
    const vec3 mapNormal = vec3(sampled.xy * scale, sampled.z);
    const mat3 TBN = mat3(normalize(T), normalize(B), N);

    return normalize(TBN * mapNormal);
}

void main()
{
    const Material material = ubo.material;
    const uint flags = materialFlags(material);

    const vec4 base = materialBaseColor(material, fragColor, fragTextureCoord, baseColorTexture);

    const uint alphaMode = uint(material.params.z);
    if(alphaMode == MATERIAL_ALPHA_MASK && base.a < material.alphaParams.x)
        discard;

    vec3 color;

    // Unlit output is the base color alone; no basis, maps or light
    if(uint(material.params.x) == MATERIAL_MODE_UNLIT)
        color = base.rgb;
    else
    {
        vec3 normal = normalize(fragNormal);
        if((flags & MATERIAL_FLAG_DERIVED_NORMALS) != 0u)
            normal = normalize(cross(dFdx(fragPosition), dFdy(fragPosition)));
        if((flags & MATERIAL_FLAG_NORMAL_TEXTURE) != 0u)
        {
            if((flags & MATERIAL_FLAG_VERTEX_TANGENT) != 0u)
                normal = perturbNormalFromTangent(normalTexture, material.metallicRoughness.z, normal, fragPosition, fragTextureCoord, fragTangent);
            else
                normal = perturbNormalFromDerivatives(normalTexture, material.metallicRoughness.z, normal, fragPosition, fragTextureCoord);
        }

        vec2 metallicRoughness = material.metallicRoughness.xy;
        if((flags & MATERIAL_FLAG_METALLIC_ROUGHNESS_TEXTURE) != 0u)
        {
            const vec3 sampled = texture(metallicRoughnessTexture, fragTextureCoord).rgb;
            metallicRoughness.y *= sampled.g;
            metallicRoughness.x *= sampled.b;
        }

        float ao = 1.0;
        if((flags & MATERIAL_FLAG_OCCLUSION_TEXTURE) != 0u)
        {
            const float occlusion = texture(occlusionTexture, fragTextureCoord).r;
            ao = mix(1.0, occlusion, material.metallicRoughness.w);
        }

        vec3 specularColor = material.specular.rgb;
        float specularWeight = material.specular.a;
        if((flags & MATERIAL_FLAG_SPECULAR_TEXTURE) != 0u)
            specularWeight *= texture(specularTexture, fragTextureCoord).a;
        if((flags & MATERIAL_FLAG_SPECULAR_COLOR_TEXTURE) != 0u)
            specularColor *= texture(specularColorTexture, fragTextureCoord).rgb;

        // The IOR sets the base reflectance, specular tints and scales it
        const vec3 specularF0 = dielectricF0(material, specularColor, specularWeight);

        float clearcoat = material.clearcoat.x;
        if((flags & MATERIAL_FLAG_CLEARCOAT_TEXTURE) != 0u)
            clearcoat *= texture(clearcoatTexture, fragTextureCoord).r;

        float clearcoatRoughness = material.clearcoat.y;
        if((flags & MATERIAL_FLAG_CLEARCOAT_ROUGHNESS_TEXTURE) != 0u)
            clearcoatRoughness *= texture(clearcoatRoughnessTexture, fragTextureCoord).g;

        vec3 clearcoatNormal = normal;
        if(clearcoat > 0.0 && (flags & MATERIAL_FLAG_CLEARCOAT_NORMAL_TEXTURE) != 0u)
        {
            if((flags & MATERIAL_FLAG_VERTEX_TANGENT) != 0u)
                clearcoatNormal = perturbNormalFromTangent(clearcoatNormalTexture, material.clearcoat.z, normal, fragPosition, fragTextureCoord, fragTangent);
            else
                clearcoatNormal = perturbNormalFromDerivatives(clearcoatNormalTexture, material.clearcoat.z, normal, fragPosition, fragTextureCoord);
        }

        vec3 emissive = material.emissiveFactor.rgb;
        if((flags & MATERIAL_FLAG_EMISSIVE_TEXTURE) != 0u)
            emissive *= texture(emissiveTexture, fragTextureCoord).rgb;

        vec3 sheenColor = material.sheen.rgb;
        if((flags & MATERIAL_FLAG_SHEEN_COLOR_TEXTURE) != 0u)
            sheenColor *= texture(sheenColorTexture, fragTextureCoord).rgb;

        float sheenRoughness = material.sheen.a;
        if((flags & MATERIAL_FLAG_SHEEN_ROUGHNESS_TEXTURE) != 0u)
            sheenRoughness *= texture(sheenRoughnessTexture, fragTextureCoord).a;

        float anisotropy = material.anisotropy.x;
        vec2 anisotropyDirection = vec2(1.0, 0.0);

        if((flags & MATERIAL_FLAG_ANISOTROPY_TEXTURE) != 0u)
        {
            const vec3 sampled = texture(anisotropyTexture, fragTextureCoord).rgb;
            anisotropyDirection = sampled.rg * 2.0 - 1.0;
            anisotropy *= sampled.b;
        }

        vec3 anisotropyTangent = vec3(1.0, 0.0, 0.0);
        vec3 anisotropyBitangent = vec3(0.0, 1.0, 0.0);

        if(anisotropy > 0.0)
        {
            const float rotation = material.anisotropy.y;
            const vec2 rotationCosSin = vec2(cos(rotation), sin(rotation));
            anisotropyDirection = mat2(
                rotationCosSin.x, rotationCosSin.y,
                -rotationCosSin.y, rotationCosSin.x
            ) * normalize(anisotropyDirection);

            if((flags & MATERIAL_FLAG_VERTEX_TANGENT) != 0u)
            {
                anisotropyTangent = fragTangent.xyz;
                anisotropyBitangent = cross(normal, anisotropyTangent) * (fragTangent.w < 0.0 ? -1.0 : 1.0);
            }
            else
            {
                const vec3 dp1 = dFdx(fragPosition);
                const vec3 dp2 = dFdy(fragPosition);
                const vec2 duv1 = dFdx(fragTextureCoord);
                const vec2 duv2 = dFdy(fragTextureCoord);
                const vec3 dp2perp = cross(dp2, normal);
                const vec3 dp1perp = cross(normal, dp1);
                anisotropyTangent = dp2perp * duv1.x + dp1perp * duv2.x;
                anisotropyBitangent = dp2perp * duv1.y + dp1perp * duv2.y;
            }

            // Keep the frame orthonormal against the shading normal
            anisotropyTangent = normalize(anisotropyTangent - normal * dot(normal, anisotropyTangent));
            anisotropyBitangent = normalize(cross(normal, anisotropyTangent));
        }

        Surface surface;
        surface.albedo = base.rgb;
        surface.normal = normal;
        surface.clearcoatNormal = clearcoatNormal;
        surface.position = fragPosition;
        surface.emissive = emissive;
        surface.dielectricF0 = specularF0;
        surface.dielectricF90 = specularWeight;
        surface.metallic = metallicRoughness.x;
        surface.roughness = metallicRoughness.y;
        surface.ao = ao;
        surface.clearcoat = clearcoat;
        surface.clearcoatRoughness = clearcoatRoughness;
        surface.sheenColor = sheenColor;
        surface.sheenRoughness = sheenRoughness;
        surface.tangent = anisotropyTangent;
        surface.bitangent = anisotropyBitangent;
        surface.anisotropyDirection = anisotropyDirection;
        surface.anisotropy = anisotropy;

        color = shadePbr(surface);
    }

    outColor = vec4(color, alphaMode == MATERIAL_ALPHA_BLEND ? base.a : 1.0);
}
