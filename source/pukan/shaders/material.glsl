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
    vec4 anisotropy; // x = strength, y = rotation
    vec4 iridescence; // x = factor, y = ior, z = min thickness, w = max thickness
    vec4 transmission; // x = factor
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
const uint MATERIAL_FLAG_ANISOTROPY_TEXTURE = 1u << 15;
const uint MATERIAL_FLAG_IRIDESCENCE_TEXTURE = 1u << 16;
const uint MATERIAL_FLAG_IRIDESCENCE_THICKNESS_TEXTURE = 1u << 17;
const uint MATERIAL_FLAG_TRANSMISSION_TEXTURE = 1u << 18;

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

layout(set = 1, binding = FRAME_IRRADIANCE) uniform sampler2D irradianceMap;
layout(set = 1, binding = FRAME_PREFILTERED) uniform sampler2D prefilteredMap;
layout(set = 1, binding = FRAME_BRDF_LUT) uniform sampler2D brdfLut;

#ifdef SKY_ANALYTIC
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
#endif

/// Last mip of the prefiltered chain
const float PREFILTERED_MAX_LOD = 5.0;

vec2 equirectUv(vec3 direction)
{
    return vec2(
        atan(direction.x, -direction.z) / (2.0 * MATERIAL_PI) + 0.5,
        acos(clamp(direction.y, -1.0, 1.0)) / MATERIAL_PI
    );
}

vec3 environmentRadiance(vec3 direction, float roughness)
{
#ifdef SKY_NONE
    return vec3(0.0);
#elif defined(SKY_ANALYTIC)
    return environment(direction);
#else
    return textureLod(prefilteredMap, equirectUv(direction), roughness * PREFILTERED_MAX_LOD).rgb;
#endif
}

/// Narkowicz 2015 ACES fit
vec3 toneMap(vec3 color)
{
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;

    return clamp((color * (a * color + b)) / (color * (c * color + d) + e), 0.0, 1.0);
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
    vec3 tangent;
    vec3 bitangent;
    vec2 anisotropyDirection;
    float dielectricF90;
    float metallic;
    float roughness;
    float ao;
    float clearcoat;
    float clearcoatRoughness;
    float sheenRoughness;
    float anisotropy;
    float iridescenceFactor;
    float iridescenceIor;
    float iridescenceThickness;
    float transmission;
    float ior;
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

// Belcour and Barla 2017, "A Practical Extension to Microfacet Theory for the
// Modeling of Varying Iridescence": three spectral samples in Fourier space
vec3 iridescenceSensitivity(float opd, vec3 shift)
{
    const float phase = 2.0 * MATERIAL_PI * opd * 1.0e-9;
    const vec3 val = vec3(5.4856e-13, 4.4201e-13, 5.2481e-13);
    const vec3 pos = vec3(1.6810e+06, 1.7953e+06, 2.2084e+06);
    const vec3 variance = vec3(4.3278e+09, 9.3046e+09, 6.6121e+09);

    vec3 xyz = val * sqrt(2.0 * MATERIAL_PI * variance)
        * cos(pos * phase + shift)
        * exp(-(phase * phase) * variance);

    xyz.x += 9.7470e-14 * sqrt(2.0 * MATERIAL_PI * 4.5282e+09)
        * cos(2.2399e+06 * phase + shift.x)
        * exp(-4.5282e+09 * (phase * phase));

    xyz /= 1.0685e-7;

    const mat3 xyzToRec709 = mat3(
         3.2404542, -0.9692660,  0.0556434,
        -1.5371385,  1.8760108, -0.2040259,
        -0.4985314,  0.0415560,  1.0572252
    );

    return xyzToRec709 * xyz;
}

float fresnelSchlick(float f0, float cosTheta)
{
    return f0 + (1.0 - f0) * pow(1.0 - cosTheta, 5.0);
}

vec3 fresnelSchlick(vec3 f0, float cosTheta)
{
    return f0 + (vec3(1.0) - f0) * pow(1.0 - cosTheta, 5.0);
}

vec3 iorFromF0(vec3 f0)
{
    const vec3 sqrtF0 = sqrt(clamp(f0, 0.0, 0.9999));
    return (vec3(1.0) + sqrtF0) / (vec3(1.0) - sqrtF0);
}

float iorToF0(float transmittedIor, float incidentIor)
{
    const float ratio = (transmittedIor - incidentIor) / (transmittedIor + incidentIor);
    return ratio * ratio;
}

vec3 iorToF0(vec3 transmittedIor, float incidentIor)
{
    const vec3 ratio = (transmittedIor - incidentIor) / (transmittedIor + incidentIor);
    return ratio * ratio;
}

/// Reflectance of a thin film of `filmIor` and `thicknessNm` over `baseF0`
vec3 evalIridescence(float outsideIor, float filmIor, float cosTheta, float thicknessNm, vec3 baseF0)
{
    filmIor = mix(outsideIor, filmIor, smoothstep(0.0, 0.03, thicknessNm));

    const float sinThetaSq = (outsideIor / filmIor) * (outsideIor / filmIor) * (1.0 - cosTheta * cosTheta);
    const float cosTheta2Sq = 1.0 - sinThetaSq;

    // Total internal reflection
    if(cosTheta2Sq < 0.0)
        return vec3(1.0);

    const float cosTheta2 = sqrt(cosTheta2Sq);

    const float r12 = fresnelSchlick(iorToF0(filmIor, outsideIor), cosTheta);
    const vec3 baseIor = iorFromF0(baseF0);
    const vec3 r23 = fresnelSchlick(iorToF0(baseIor, filmIor), cosTheta2);

    const float t121 = 1.0 - r12;
    const vec3 r123 = clamp(r12 * r23, 1e-5, 0.9999);
    const vec3 rs = (t121 * t121) * r23 / (vec3(1.0) - r123);

    const float phi12 = filmIor < outsideIor ? MATERIAL_PI : 0.0;
    const vec3 phi23 = mix(vec3(0.0), vec3(MATERIAL_PI), lessThan(baseIor, vec3(filmIor)));
    const vec3 phi = vec3(MATERIAL_PI - phi12) + phi23;

    const float opd = 2.0 * filmIor * thicknessNm * cosTheta2;
    const vec3 r123Sqrt = sqrt(r123);

    vec3 reflectance = r12 + rs;
    vec3 amplitude = rs - t121;

    for(int m = 1; m <= 2; ++m)
    {
        amplitude *= r123Sqrt;
        reflectance += amplitude * 2.0 * iridescenceSensitivity(float(m) * opd, float(m) * phi);
    }

    return max(reflectance, vec3(0.0));
}

float D_GGX_anisotropic(float NdotH, float TdotH, float BdotH, float at, float ab)
{
    const float a2 = at * ab;
    const vec3 f = vec3(ab * TdotH, at * BdotH, a2 * NdotH);
    const float w2 = a2 / dot(f, f);

    return a2 * w2 * w2 / MATERIAL_PI;
}

float V_GGX_anisotropic(
    float NdotL,
    float NdotV,
    float BdotV,
    float TdotV,
    float TdotL,
    float BdotL,
    float at,
    float ab
)
{
    const float GGXV = NdotL * length(vec3(at * TdotV, ab * BdotV, NdotV));
    const float GGXL = NdotV * length(vec3(at * TdotL, ab * BdotL, NdotL));

    return clamp(0.5 / (GGXV + GGXL), 0.0, 1.0);
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

    vec3 F0 = mix(s.dielectricF0, s.albedo, metallic);

    if(s.iridescenceFactor > 0.0)
    {
        const vec3 dielectric = evalIridescence(1.0, s.iridescenceIor, NdotV, s.iridescenceThickness, s.dielectricF0);
        const vec3 metal = evalIridescence(1.0, s.iridescenceIor, NdotV, s.iridescenceThickness, s.albedo);
        F0 = mix(F0, mix(dielectric, metal, metallic), s.iridescenceFactor);
    }

    const vec3 F90 = vec3(mix(s.dielectricF90, 1.0, metallic));
    const vec3 F = F0 + (F90 - F0) * pow(1.0 - VdotH, 5.0);

    vec3 specular;

    if(s.anisotropy > 0.0)
    {
        const float at = mix(a, 1.0, s.anisotropy * s.anisotropy);
        const float ab = a;

        const vec3 anisotropicT = normalize(s.tangent * s.anisotropyDirection.x + s.bitangent * s.anisotropyDirection.y);
        const vec3 anisotropicB = normalize(cross(N, anisotropicT));

        const float TdotL = dot(anisotropicT, L);
        const float BdotL = dot(anisotropicB, L);
        const float TdotV = dot(anisotropicT, V);
        const float BdotV = dot(anisotropicB, V);
        const float TdotH = dot(anisotropicT, H);
        const float BdotH = dot(anisotropicB, H);

        const float anisotropicD = D_GGX_anisotropic(NdotH, TdotH, BdotH, at, ab);
        const float anisotropicV = V_GGX_anisotropic(NdotL, NdotV, BdotV, TdotV, TdotL, BdotL, at, ab);

        specular = F * anisotropicV * anisotropicD;
    }
    else
        specular = D * G * F / max(4.0 * NdotL * NdotV, 0.001);

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
    const float iblIntensity = frameUbo.frame.exposureParams.y;

#ifdef SKY_NONE
    const vec3 reflection = vec3(0.0);
    const vec3 ambient = vec3(0.0);
#elif defined(SKY_ANALYTIC)
    const vec3 irradiance = environment(N);
    const vec3 reflection = mix(environment(R), vec3(0.1), roughness);
    const vec3 Fenv = fresnelSchlickRoughness(NdotV, F0, roughness);
    const vec3 kDEnv = (1.0 - Fenv) * (1.0 - metallic);
    const vec3 ambient = (kDEnv * s.albedo * irradiance + reflection * Fenv) * s.ao * iblIntensity;
#else
    const vec3 irradiance = texture(irradianceMap, equirectUv(N)).rgb;
    const vec3 reflection = textureLod(prefilteredMap, equirectUv(R), roughness * PREFILTERED_MAX_LOD).rgb;
    const vec2 environmentBrdf = texture(brdfLut, vec2(NdotV, roughness)).rg;
    const vec3 Fenv = F0 * environmentBrdf.x + environmentBrdf.y;
    const vec3 kDEnv = (1.0 - Fenv) * (1.0 - metallic);
    const vec3 ambient = (kDEnv * s.albedo * irradiance + reflection * Fenv) * s.ao * iblIntensity;
#endif

    const float coating = 1.0 - clearcoat * coatFresnel;

    vec3 sheenDirect = vec3(0.0);
    vec3 sheenAmbient = vec3(0.0);

    if(maxComponent(s.sheenColor) > 0.0)
    {
        const float sheenRoughness = clamp(s.sheenRoughness, 0.0001, 1.0);
        sheenDirect = s.sheenColor * D_Charlie(sheenRoughness, NdotH) * V_Neubelt(NdotV, NdotL);
        sheenAmbient = s.sheenColor * sheenEnvironmentBRDF(N, V, sheenRoughness) * reflection;
    }

    vec3 color = direct
        + sheenDirect * lightColor * NdotL
        + (ambient + sheenAmbient) * coating
        + s.emissive * coating;

    if(s.transmission > 0.0)
    {
        vec3 direction = refract(-V, N, 1.0 / max(s.ior, 1.0));

        if(dot(direction, direction) == 0.0)
            direction = -N;

        // No colour behind the surface yet, so the environment stands in for it
        const vec3 transmitted = environmentRadiance(direction, roughness) * s.albedo;
        const vec3 fresnel = fresnelSchlick(s.dielectricF0, NdotV);

        color = mix(color, transmitted + reflection * fresnel, s.transmission);
    }

    return color;
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
        surface.anisotropy = 0.0;
        surface.iridescenceFactor = material.iridescence.x;
        surface.iridescenceIor = material.iridescence.y;
        surface.iridescenceThickness = material.iridescence.w;
        surface.transmission = material.transmission.x;
        surface.ior = material.iorParams.x;

        return shadePbr(surface);
    }

    return albedo;
}
