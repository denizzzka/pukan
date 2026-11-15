#ifndef PUKAN_SHADOW_GLSL
#define PUKAN_SHADOW_GLSL

layout(set = 1, binding = FRAME_SHADOW_MAP) uniform sampler2DShadow shadowMap;
layout(set = 1, binding = FRAME_SHADOW_MAP1) uniform sampler2DShadow shadowMap1;
layout(set = 1, binding = FRAME_SHADOW_MAP2) uniform sampler2DShadow shadowMap2;
layout(set = 1, binding = FRAME_LOCAL_SHADOWS) uniform sampler2DShadow localShadowMap;

/// Four half-texel taps: each bilinear comparison covers 2x2, together a 3x3 box
float shadowPcf(sampler2DShadow map, vec2 uv, float ordinate, vec2 halfTexel)
{
    float total = texture(map, vec3(uv + vec2(-halfTexel.x, -halfTexel.y), ordinate));
    total += texture(map, vec3(uv + vec2(halfTexel.x, -halfTexel.y), ordinate));
    total += texture(map, vec3(uv + vec2(-halfTexel.x, halfTexel.y), ordinate));
    total += texture(map, vec3(uv + vec2(halfTexel.x, halfTexel.y), ordinate));

    return total * 0.25;
}

/// Fraction of the sun that reaches a point through one cascade's map
float shadowFactorCascade(mat4 shadowViewProj, sampler2DShadow map, float bias, vec3 position, vec3 normal)
{
    // A small normal offset keeps a surface from shadowing itself
    const vec4 clip = shadowViewProj * vec4(position + normal * 0.015, 1.0);

    if(clip.w <= 0.0)
        return 1.0;

    const vec3 ndc = clip.xyz / clip.w;
    const vec2 uv = ndc.xy * 0.5 + 0.5;

    if(any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))))
        return 1.0;

    const vec2 halfTexel = 0.5 / vec2(textureSize(map, 0));

    return shadowPcf(map, uv, ndc.z + bias, halfTexel);
}

/// Fraction of one local tile that reaches a point
float tileShadowFactor(mat4 viewProj, float tile, float bias, vec3 position, vec3 normal)
{
    if(frameUbo.frame.localShadowParams.w < 0.5)
        return 1.0;

    const vec4 clip = viewProj * vec4(position + normal * 0.02, 1.0);

    if(clip.w <= 0.0)
        return 1.0;

    const vec3 ndc = clip.xyz / clip.w;

    if(ndc.z <= 0.0 || ndc.z >= 1.0)
        return 1.0;

    const vec2 uv = ndc.xy * 0.5 + 0.5;

    if(any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0))))
        return 1.0;

    const float tiles = frameUbo.frame.localShadowParams.y;
    const float invTiles = frameUbo.frame.localShadowParams.x;
    const vec2 origin = vec2(mod(tile, tiles), floor(tile / tiles)) * invTiles;

    // A tap at a tile edge would read the neighbour, so keep it inside its tile
    const vec2 halfTexel = vec2(0.5 * frameUbo.frame.localShadowParams.z);
    const vec2 low = origin + halfTexel;
    const vec2 high = origin + invTiles - halfTexel;
    const vec2 atlasUv = origin + uv * invTiles;
    const float ordinate = ndc.z + bias;

    float total = texture(localShadowMap, vec3(clamp(atlasUv + vec2(-halfTexel.x, -halfTexel.y), low, high), ordinate));
    total += texture(localShadowMap, vec3(clamp(atlasUv + vec2(halfTexel.x, -halfTexel.y), low, high), ordinate));
    total += texture(localShadowMap, vec3(clamp(atlasUv + vec2(-halfTexel.x, halfTexel.y), low, high), ordinate));
    total += texture(localShadowMap, vec3(clamp(atlasUv + vec2(halfTexel.x, halfTexel.y), low, high), ordinate));

    return total * 0.25;
}

/// Fraction of a spot light that reaches a point
float localShadowFactor(Light light, vec3 position, vec3 normal)
{
    return tileShadowFactor(light.shadowViewProj[0], light.params.z, light.params.w, position, normal);
}

/// Fraction of a point light that reaches a point, through the face its direction falls in
float pointShadowFactor(Light light, vec3 position, vec3 normal)
{
    const vec3 away = position - light.positionRadius.xyz;
    const vec3 magnitude = abs(away);
    uint face;

    if(magnitude.x >= magnitude.y && magnitude.x >= magnitude.z)
        face = away.x >= 0.0 ? 0u : 1u;
    else if(magnitude.y >= magnitude.z)
        face = away.y >= 0.0 ? 2u : 3u;
    else
        face = away.z >= 0.0 ? 4u : 5u;

    return tileShadowFactor(light.shadowViewProj[face], light.params.z + float(face),
        light.params.w, position, normal);
}

/// Fraction of the sun one named cascade lets through
float shadowFactorAt(uint cascade, vec3 position, vec3 normal)
{
    if(cascade == 0u)
        return shadowFactorCascade(frameUbo.frame.shadowViewProj[0], shadowMap,
            frameUbo.frame.shadowParams.y, position, normal);

    if(cascade == 1u)
        return shadowFactorCascade(frameUbo.frame.shadowViewProj[1], shadowMap1,
            frameUbo.frame.shadowParams.z, position, normal);

    return shadowFactorCascade(frameUbo.frame.shadowViewProj[2], shadowMap2,
        frameUbo.frame.shadowParams.w, position, normal);
}

/// Fraction of the sun that reaches a point, from the cascade it falls in
float shadowFactor(vec3 position, vec3 normal)
{
    if(frameUbo.frame.shadowParams.x < 0.5)
        return 1.0;

    // Clip w is the view depth the projection keeps, so the split needs no camera basis
    const vec4 splits = frameUbo.frame.shadowSplits;
    const float depth = (frameUbo.frame.viewProj * vec4(position, 1.0)).w;

    if(depth < splits.x)
    {
        const float here = shadowFactorAt(0u, position, normal);
        const float band = splits.x * splits.w;

        if(depth <= splits.x - band)
            return here;

        return mix(here, shadowFactorAt(1u, position, normal), (depth - (splits.x - band)) / band);
    }

    if(depth < splits.y)
    {
        const float here = shadowFactorAt(1u, position, normal);
        const float band = (splits.y - splits.x) * splits.w;

        if(depth <= splits.y - band)
            return here;

        return mix(here, shadowFactorAt(2u, position, normal), (depth - (splits.y - band)) / band);
    }

    return shadowFactorAt(2u, position, normal);
}

#endif
