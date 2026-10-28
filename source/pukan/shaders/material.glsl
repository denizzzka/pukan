#include "frame.glsl"

struct Material
{
    vec4 baseColorFactor;
    vec4 emissiveFactor;
    vec4 metallicRoughness;
    vec4 alphaParams;
    ivec4 params; // x = mode, y = flags, z = alpha mode
    vec4 specular; // rgb = F0 color, a = strength
    vec4 iorParams; // x = index of refraction
    vec4 clearcoat; // x = factor, y = roughness, z = normal scale
    vec4 sheen; // rgb = color, a = roughness
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
const uint MATERIAL_FLAG_VERTEX_TANGENT = 1u << 7;
const uint MATERIAL_FLAG_SPECULAR_TEXTURE = 1u << 8;
const uint MATERIAL_FLAG_SPECULAR_COLOR_TEXTURE = 1u << 9;
const uint MATERIAL_FLAG_CLEARCOAT_TEXTURE = 1u << 10;
const uint MATERIAL_FLAG_CLEARCOAT_ROUGHNESS_TEXTURE = 1u << 11;
const uint MATERIAL_FLAG_CLEARCOAT_NORMAL_TEXTURE = 1u << 12;
const uint MATERIAL_FLAG_SHEEN_COLOR_TEXTURE = 1u << 13;
const uint MATERIAL_FLAG_SHEEN_ROUGHNESS_TEXTURE = 1u << 14;

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

struct Surface
{
    vec3 albedo;
    vec3 normal;
    vec3 clearcoatNormal;
    vec3 position;
    vec3 emissive;
    vec3 dielectricF0;
    vec3 sheenColor;
    float dielectricF90;
    float metallic;
    float roughness;
    float ao;
    float clearcoat;
    float clearcoatRoughness;
    float sheenRoughness;
};

// Estevez and Kulla 2017, "Production Friendly Microfacet Sheen BRDF"
float D_Charlie(float roughness, float NdotH)
{
    const float alpha = roughness * roughness;
    const float invAlpha = 1.0 / alpha;
    const float cos2h = NdotH * NdotH;
    const float sin2h = max(1.0 - cos2h, 0.0078125);

    return (2.0 + invAlpha) * pow(sin2h, invAlpha * 0.5) / (2.0 * MATERIAL_PI);
}

float V_Neubelt(float NdotV, float NdotL)
{
    return clamp(1.0 / (4.0 * (NdotL + NdotV - NdotL * NdotV)), 0.0, 1.0);
}

// Curve fit to the Charlie BRDF integrated over the hemisphere, as in Filament
float sheenEnvironmentBRDF(vec3 N, vec3 V, float roughness)
{
    const float NdotV = clamp(dot(N, V), 0.0, 1.0);
    const float r2 = roughness * roughness;
    const float rInv = 1.0 / (roughness + 0.1);
    const float a = -1.9362 + 1.0678 * roughness + 0.4573 * r2 - 0.8469 * rInv;
    const float b = -0.6014 + 0.5538 * roughness - 0.4670 * r2 - 0.1255 * rInv;

    return clamp(exp(a * NdotV + b), 0.0, 1.0);
}

float maxComponent(vec3 v)
{
    return max(max(v.r, v.g), v.b);
}

vec3 shadePbr(Surface s)
{
    const vec3 N = normalize(s.normal);
    const vec3 V = normalize(frameUbo.frame.cameraPosition.xyz - s.position);
    const vec3 L = normalize(frameUbo.frame.lightDirection.xyz);
    const vec3 H = normalize(V + L);
    const vec3 lightColor = frameUbo.frame.lightColor.rgb;

    const float NdotL = max(dot(N, L), 0.0);
    const float NdotV = max(dot(N, V), 0.0);
    const float NdotH = max(dot(N, H), 0.0);
    const float VdotH = max(dot(V, H), 0.0);

    const float metallic = clamp(s.metallic, 0.0, 1.0);
    const float roughness = clamp(s.roughness, 0.04, 1.0);

    const float a = roughness * roughness;
    const float a2 = a * a;
    const float denominator = NdotH * NdotH * (a2 - 1.0) + 1.0;
    const float D = a2 / (MATERIAL_PI * denominator * denominator);

    const float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    const float G = (NdotL / (NdotL * (1.0 - k) + k)) * (NdotV / (NdotV * (1.0 - k) + k));

    const vec3 F0 = mix(s.dielectricF0, s.albedo, metallic);
    const vec3 F90 = vec3(mix(s.dielectricF90, 1.0, metallic));
    const vec3 F = F0 + (F90 - F0) * pow(1.0 - VdotH, 5.0);
    const vec3 specular = D * G * F / max(4.0 * NdotL * NdotV, 0.001);
    const vec3 kD = (1.0 - F) * (1.0 - metallic);

    vec3 brdf = kD * s.albedo / MATERIAL_PI + specular;

    const float clearcoat = clamp(s.clearcoat, 0.0, 1.0);
    const float clearcoatRoughness = clamp(s.clearcoatRoughness, 0.04, 1.0);
    float coatFresnel = 0.0;

    if(clearcoat > 0.0)
    {
        const vec3 Nc = normalize(s.clearcoatNormal);
        const float NdotLc = max(dot(Nc, L), 0.0);
        const float NdotVc = max(dot(Nc, V), 0.0);
        const float NdotHc = max(dot(Nc, H), 0.0);

        const float aC = clearcoatRoughness * clearcoatRoughness;
        const float aC2 = aC * aC;
        const float denominatorC = NdotHc * NdotHc * (aC2 - 1.0) + 1.0;
        const float Dc = aC2 / (MATERIAL_PI * denominatorC * denominatorC);

        const float kC = (clearcoatRoughness + 1.0) * (clearcoatRoughness + 1.0) / 8.0;
        const float Gc = (NdotLc / (NdotLc * (1.0 - kC) + kC)) * (NdotVc / (NdotVc * (1.0 - kC) + kC));

        coatFresnel = 0.04 + 0.96 * pow(1.0 - NdotVc, 5.0);

        const vec3 clearcoatBrdf = vec3(Dc * Gc / max(4.0 * NdotLc * NdotVc, 0.001));
        brdf = mix(brdf, clearcoatBrdf, clearcoat * coatFresnel);
    }

    const vec3 direct = brdf * lightColor * NdotL;

    const vec3 R = reflect(-V, N);
    const vec3 irradiance = environment(N);
    const vec3 reflection = mix(environment(R), vec3(0.1), roughness);
    const vec3 Fenv = fresnelSchlickRoughness(NdotV, F0, roughness);
    const vec3 kDEnv = (1.0 - Fenv) * (1.0 - metallic);
    const vec3 ambient = (kDEnv * s.albedo * irradiance + reflection * Fenv) * s.ao;

    const float coating = 1.0 - clearcoat * coatFresnel;

    vec3 sheenDirect = vec3(0.0);
    vec3 sheenAmbient = vec3(0.0);

    if(maxComponent(s.sheenColor) > 0.0)
    {
        const float sheenRoughness = clamp(s.sheenRoughness, 0.0001, 1.0);
        sheenDirect = s.sheenColor * D_Charlie(sheenRoughness, NdotH) * V_Neubelt(NdotV, NdotL);
        sheenAmbient = s.sheenColor * sheenEnvironmentBRDF(N, V, sheenRoughness) * environment(R);
    }

    return direct
        + sheenDirect * lightColor * NdotL
        + (ambient + sheenAmbient) * coating
        + s.emissive * coating;
}

// The IOR sets the base reflectance, specular tints and scales it
vec3 dielectricF0(Material material, vec3 specularColor, float specularWeight)
{
    const float ior = material.iorParams.x;
    const float f0Ior = pow((ior - 1.0) / (ior + 1.0), 2.0);

    return min(vec3(f0Ior) * specularColor, vec3(1.0)) * specularWeight;
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
    {
        Surface surface;
        surface.albedo = albedo;
        surface.normal = unitNormal;
        surface.clearcoatNormal = unitNormal;
        surface.position = worldPosition;
        surface.emissive = emissive;
        surface.dielectricF0 = dielectricF0(material, material.specular.rgb, material.specular.a);
        surface.dielectricF90 = material.specular.a;
        surface.metallic = material.metallicRoughness.x;
        surface.roughness = material.metallicRoughness.y;
        surface.ao = 1.0;
        surface.clearcoat = material.clearcoat.x;
        surface.clearcoatRoughness = material.clearcoat.y;
        surface.sheenColor = material.sheen.rgb;
        surface.sheenRoughness = material.sheen.a;

        return shadePbr(surface);
    }

    return albedo;
}
