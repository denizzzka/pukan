#ifndef PUKAN_FOG_GLSL
#define PUKAN_FOG_GLSL

/// Slices the fog volume is split into along the view ray; fog_slices in
/// volumetric_fog.d must match
#define FOG_SLICE_COUNT 64

const float FOG_PI = 3.14159265358979323846;

/// A box or an ellipsoid of denser fog, as fog_inject.comp reads it
struct FogVolume
{
    vec4 centerShape;        // xyz = centre, w = 0 box, 1 ellipsoid
    vec4 halfExtentsDensity; // xyz = half extents, w = density
    vec4 albedoEmission;     // rgb = albedo, a = emission energy
    vec4 emissionEdge;       // rgb = emission colour, a = fade near the edge
    vec4 noiseScale;         // x = how much noise breaks the shape, y = metres between features
};

/// Position of a view distance in the volume, zero at the fog start
float fogSliceOfDepth(float depth)
{
    const vec4 params = frameUbo.frame.fogDepth;
    return clamp((log2(max(depth, params.x)) - params.z) * params.w, 0.0, 1.0);
}

/// View distance at a position in the volume
float fogDepthOfSlice(float slice)
{
    const vec4 params = frameUbo.frame.fogDepth;
    return params.x * exp2(slice / params.w);
}

/// Henyey-Greenstein phase; positive anisotropy scatters toward the light
float fogPhase(float cosTheta)
{
    const float g = clamp(frameUbo.frame.fogParams.z, -0.95, 0.95);
    const float g2 = g * g;
    const float denominator = max(1.0 + g2 - 2.0 * g * cosTheta, 1e-4);

    return (1.0 - g2) / (4.0 * FOG_PI * denominator * sqrt(denominator));
}

/// Optical depth of the ground layer along the view ray to a position
float heightFogDepth(vec3 position)
{
    const vec4 params = frameUbo.frame.heightFogParams;

    if(params.x < 0.5 || params.y <= 0.0)
        return 0.0;

    const vec3 origin = frameUbo.frame.cameraPosition.xyz;
    const float path = distance(origin, position);

    if(path <= 0.0)
        return 0.0;

    const float falloff = max(params.w, 1e-4);
    const float start = params.y * exp(-falloff * (origin.y - params.z));
    const float delta = falloff * (position.y - origin.y);

    // The layer thins with height, so the average over the ray is not the midpoint
    const float average = abs(delta) < 1e-3 ? 1.0 - 0.5 * delta : (1.0 - exp(-delta)) / delta;

    return start * path * max(average, 0.0);
}

/// A ground-hugging layer: it hides the scene with distance and with height
vec3 applyHeightFog(vec3 color, vec3 position)
{
    if(frameUbo.frame.heightFogParams.x < 0.5)
        return color;

    const float transmittance = exp(-heightFogDepth(position));
    return color * transmittance + frameUbo.frame.heightFogColor.rgb * (1.0 - transmittance);
}

/// Equirectangular coordinates of a direction, matching the IBL probe layout
vec2 fogEquirectUv(vec3 direction)
{
    return vec2(
        atan(direction.x, -direction.z) / (2.0 * FOG_PI) + 0.5,
        acos(clamp(direction.y, -1.0, 1.0)) / FOG_PI
    );
}

/// Value noise of a lattice, the base of the cloud shape
float fogLattice(vec3 cell)
{
    cell = fract(cell * 0.3183099 + vec3(0.71, 0.113, 0.419));
    cell *= 17.0;

    return fract(cell.x * cell.y * cell.z * (cell.x + cell.y + cell.z));
}

float fogValueNoise(vec3 point)
{
    const vec3 cell = floor(point);
    const vec3 local = fract(point);
    const vec3 blend = local * local * (3.0 - 2.0 * local);

    const float c000 = fogLattice(cell);
    const float c100 = fogLattice(cell + vec3(1.0, 0.0, 0.0));
    const float c010 = fogLattice(cell + vec3(0.0, 1.0, 0.0));
    const float c110 = fogLattice(cell + vec3(1.0, 1.0, 0.0));
    const float c001 = fogLattice(cell + vec3(0.0, 0.0, 1.0));
    const float c101 = fogLattice(cell + vec3(1.0, 0.0, 1.0));
    const float c011 = fogLattice(cell + vec3(0.0, 1.0, 1.0));
    const float c111 = fogLattice(cell + vec3(1.0, 1.0, 1.0));

    const float bottom = mix(mix(c000, c100, blend.x), mix(c010, c110, blend.x), blend.y);
    const float top = mix(mix(c001, c101, blend.x), mix(c011, c111, blend.x), blend.y);

    return mix(bottom, top, blend.z);
}

/// Three octaves remapped so the volume keeps dense hearts and thin gaps
float fogCloud(vec3 point)
{
    float total = 0.0;
    float amplitude = 0.5;

    for(uint i = 0u; i < 3u; ++i)
    {
        total += amplitude * fogValueNoise(point);
        point *= 2.03;
        amplitude *= 0.5;
    }

    return smoothstep(0.42, 0.72, total);
}

/// Interleaved gradient noise, hiding the slice steps of a still image
float fogDither(vec2 pixel)
{
    return fract(52.9829189 * fract(dot(pixel, vec2(0.06711056, 0.00583715))));
}

#endif
