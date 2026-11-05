/// Narkowicz 2015 ACES fit
vec3 toneMapAces(vec3 color)
{
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;

    return clamp((color * (a * color + b)) / (color * (c * color + d) + e), 0.0, 1.0);
}

vec3 toneMapReinhard(vec3 color, float white)
{
    const float whiteSquared = white * white;
    const vec3 whiteSquaredColor = whiteSquared * color;

    return (whiteSquaredColor + color * color) / (whiteSquaredColor + whiteSquared);
}

vec3 toneMapFilmic(vec3 color, float white)
{
    const float exposureBias = 2.0;
    const float A = 0.22 * exposureBias * exposureBias;
    const float B = 0.30 * exposureBias;
    const float C = 0.10;
    const float D = 0.20;
    const float E = 0.01;
    const float F = 0.30;

    const vec3 tonemapped = ((color * (A * color + C * B) + D * E) / (color * (A * color + B) + D * F)) - E / F;
    const float whiteTonemapped = ((white * (A * white + C * B) + D * E) / (white * (A * white + B) + D * F)) - E / F;

    return tonemapped / whiteTonemapped;
}

// Polynomial approximation of EaryChow's AgX sigmoid, from Godot's tonemap.glsl
vec3 agxContrastApprox(vec3 x)
{
    const vec3 x2 = x * x;
    const vec3 x4 = x2 * x2;

    return 0.021 * x + 4.0111 * x2 - 25.682 * x2 * x + 70.359 * x4 - 74.778 * x4 * x + 27.069 * x4 * x2;
}

/// Godot's AgX, after EaryChow's LUT generator
vec3 toneMapAgx(vec3 color)
{
    const mat3 srgbToRec2020AgxInset = mat3(
        0.54490813676363087053, 0.14044005884001287035, 0.088827411851915368603,
        0.37377945959812267119, 0.75410959864013760045, 0.17887712465043811023,
        0.081384976686407536266, 0.10543358536857773485, 0.73224999956948382528);

    const mat3 agxOutsetRec2020ToSrgb = mat3(
        1.9645509602733325934, -0.29932243390911083839, -0.16436833806080403409,
        -0.85585845117807513559, 1.3264510741502356555, -0.23822464068860595117,
        -0.10886710826831608324, -0.027084020983874825605, 1.402665347143271889);

    const float minEv = -12.4739311883324;
    const float maxEv = 4.02606881166759;

    color = max(color, vec3(2e-10));
    color = srgbToRec2020AgxInset * color;
    color = clamp(log2(color), minEv, maxEv);
    color = (color - minEv) / (maxEv - minEv);
    color = agxContrastApprox(color);
    color = pow(color, vec3(2.4));
    color = agxOutsetRec2020ToSrgb * color;

    return color;
}

vec3 toneMap(vec3 color, uint mode, float white)
{
    color = max(color, vec3(0.0));

    switch(mode)
    {
        case 0u: return clamp(color, 0.0, 1.0);
        case 1u: return clamp(toneMapReinhard(color, white), 0.0, 1.0);
        case 2u: return clamp(toneMapFilmic(color, white), 0.0, 1.0);
        case 3u: return clamp(toneMapAces(color), 0.0, 1.0);
        case 4u: return clamp(toneMapAgx(color), 0.0, 1.0);
        default: return clamp(toneMapAces(color), 0.0, 1.0);
    }
}

