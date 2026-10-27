struct Material
{
    vec4 baseColorFactor;
    vec4 emissiveFactor;
    ivec4 params; // x = mode, y = flags
};

const uint MATERIAL_MODE_UNLIT = 0u;
const uint MATERIAL_MODE_LIT = 1u;
const uint MATERIAL_MODE_NORMALS_DEBUG = 2u;

const uint MATERIAL_FLAG_VERTEX_COLOR = 1u << 0;
const uint MATERIAL_FLAG_BASE_COLOR_TEXTURE = 1u << 1;

uint materialFlags(Material material)
{
    return uint(material.params.y);
}

vec3 materialAlbedo(Material material, vec3 tint, vec2 uv, sampler2D baseColorTexture)
{
    vec3 albedo = material.baseColorFactor.rgb;

    if((materialFlags(material) & MATERIAL_FLAG_VERTEX_COLOR) != 0u)
        albedo *= tint;

    if((materialFlags(material) & MATERIAL_FLAG_BASE_COLOR_TEXTURE) != 0u)
        albedo *= texture(baseColorTexture, uv).rgb;

    return albedo;
}

vec3 shadeMaterial(Material material, vec3 albedo, vec3 normal)
{
    const vec3 unitNormal = normalize(normal);
    const uint mode = uint(material.params.x);
    const vec3 emissive = material.emissiveFactor.rgb;

    if(mode == MATERIAL_MODE_NORMALS_DEBUG)
        return mix(unitNormal * 0.5 + 0.5, albedo, 0.2);

    if(mode == MATERIAL_MODE_LIT)
    {
        // TODO: world-space light; model-space light rotates with the object.
        const vec3 lightDirection = normalize(vec3(0.35, 0.5, 0.8));
        return albedo * (0.6 + 0.6 * max(dot(unitNormal, lightDirection), 0.0)) + emissive;
    }

    return albedo + emissive;
}
