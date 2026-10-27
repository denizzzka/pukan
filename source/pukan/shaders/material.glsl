#include "frame.glsl"

struct Material
{
    vec4 baseColorFactor;
    vec4 emissiveFactor;
    vec4 metallicRoughness;
    vec4 alphaParams;
    ivec4 params; // x = mode, y = flags, z = alpha mode
};

const uint MATERIAL_MODE_UNLIT = 0u;
const uint MATERIAL_MODE_LIT = 1u;
const uint MATERIAL_MODE_NORMALS_DEBUG = 2u;
const uint MATERIAL_MODE_PBR = 3u;

const uint MATERIAL_FLAG_VERTEX_COLOR = 1u << 0;
const uint MATERIAL_FLAG_BASE_COLOR_TEXTURE = 1u << 1;
const uint MATERIAL_FLAG_METALLIC_ROUGHNESS_TEXTURE = 1u << 2;
const uint MATERIAL_FLAG_NORMAL_TEXTURE = 1u << 3;
const uint MATERIAL_FLAG_OCCLUSION_TEXTURE = 1u << 4;
const uint MATERIAL_FLAG_EMISSIVE_TEXTURE = 1u << 5;
const uint MATERIAL_FLAG_DERIVED_NORMALS = 1u << 6;

const uint MATERIAL_ALPHA_OPAQUE = 0u;
const uint MATERIAL_ALPHA_MASK = 1u;
const uint MATERIAL_ALPHA_BLEND = 2u;

const float MATERIAL_PI = 3.14159265358979323846;

uint materialFlags(Material material)
{
    return uint(material.params.y);
}

vec4 materialBaseColor(Material material, vec3 tint, vec2 uv, sampler2D baseColorTexture)
{
    vec4 base = material.baseColorFactor;

    if((materialFlags(material) & MATERIAL_FLAG_VERTEX_COLOR) != 0u)
        base.rgb *= tint;

    if((materialFlags(material) & MATERIAL_FLAG_BASE_COLOR_TEXTURE) != 0u)
        base *= texture(baseColorTexture, uv);

    return base;
}

vec3 materialAlbedo(Material material, vec3 tint, vec2 uv, sampler2D baseColorTexture)
{
    return materialBaseColor(material, tint, uv, baseColorTexture).rgb;
}

vec3 environment(vec3 direction)
{
    const vec3 ground = vec3(0.04, 0.035, 0.03);
    const vec3 sky = vec3(0.35, 0.45, 0.65);
    const float horizon = clamp(direction.y * 0.5 + 0.5, 0.0, 1.0);

    return mix(ground, sky, horizon);
}

vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness)
{
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(1.0 - cosTheta, 5.0);
}

vec3 shadePbr(
    vec3 albedo,
    vec3 normal,
    vec3 worldPosition,
    float metallic,
    float roughness,
    float ao,
    vec3 emissive
)
{
    const vec3 N = normalize(normal);
    const vec3 V = normalize(frameUbo.frame.cameraPosition.xyz - worldPosition);
    const vec3 L = normalize(frameUbo.frame.lightDirection.xyz);
    const vec3 H = normalize(V + L);
    const vec3 lightColor = frameUbo.frame.lightColor.rgb;

    const float NdotL = max(dot(N, L), 0.0);
    const float NdotV = max(dot(N, V), 0.0);
    const float NdotH = max(dot(N, H), 0.0);
    const float VdotH = max(dot(V, H), 0.0);

    metallic = clamp(metallic, 0.0, 1.0);
    roughness = clamp(roughness, 0.04, 1.0);

    const float a = roughness * roughness;
    const float a2 = a * a;
    const float denominator = NdotH * NdotH * (a2 - 1.0) + 1.0;
    const float D = a2 / (MATERIAL_PI * denominator * denominator);

    const float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    const float G = (NdotL / (NdotL * (1.0 - k) + k)) * (NdotV / (NdotV * (1.0 - k) + k));

    const vec3 F0 = mix(vec3(0.04), albedo, metallic);
    const vec3 F = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
    const vec3 specular = D * G * F / max(4.0 * NdotL * NdotV, 0.001);
    const vec3 kD = (1.0 - F) * (1.0 - metallic);
    const vec3 direct = (kD * albedo / MATERIAL_PI + specular) * lightColor * NdotL;

    const vec3 R = reflect(-V, N);
    const vec3 irradiance = environment(N);
    const vec3 reflection = mix(environment(R), vec3(0.1), roughness);
    const vec3 Fenv = fresnelSchlickRoughness(NdotV, F0, roughness);
    const vec3 kDEnv = (1.0 - Fenv) * (1.0 - metallic);
    const vec3 ambient = (kDEnv * albedo * irradiance + reflection * Fenv) * ao;

    return direct + ambient + emissive;
}

vec3 shadeMaterial(Material material, vec3 albedo, vec3 normal, vec3 worldPosition)
{
    const vec3 unitNormal = normalize(normal);
    const uint mode = uint(material.params.x);
    const vec3 emissive = material.emissiveFactor.rgb;

    if(mode == MATERIAL_MODE_NORMALS_DEBUG)
        return mix(unitNormal * 0.5 + 0.5, albedo, 0.2);

    if(mode == MATERIAL_MODE_LIT)
    {
        const vec3 lightDirection = normalize(frameUbo.frame.lightDirection.xyz);
        return albedo * (0.6 + 0.6 * max(dot(unitNormal, lightDirection), 0.0)) + emissive;
    }

    if(mode == MATERIAL_MODE_PBR)
        return shadePbr(
            albedo,
            unitNormal,
            worldPosition,
            material.metallicRoughness.x,
            material.metallicRoughness.y,
            1.0,
            emissive
        );

    return albedo + emissive;
}
