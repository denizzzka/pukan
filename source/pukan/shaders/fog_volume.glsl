#ifndef PUKAN_FOG_VOLUME_GLSL
#define PUKAN_FOG_VOLUME_GLSL

#include "fog.glsl"

layout(set = 1, binding = FRAME_FOG_VOLUME) uniform sampler3D fogVolume;

/// Light the medium scatters toward a world position and the transmittance
/// that survives to it; rgb = light, a = transmittance
vec4 sampleFog(vec3 position)
{
    const vec2 uv = gl_FragCoord.xy * frameUbo.frame.fogScreen.xy;
    const float depth = length(position - frameUbo.frame.cameraPosition.xyz);
    const float slice = fogSliceOfDepth(depth);

    // Dither by one slice, so neighbouring pixels read neighbouring slices
    const float width = 1.0 / float(FOG_SLICE_COUNT);
    const float transmittance = texture(fogVolume, vec3(uv, slice)).a;
    const float next = texture(fogVolume, vec3(uv, min(slice + width, 1.0))).a;

    // A dense cloud already differs between slices, and the jitter would only
    // turn its noise into grain; a thin medium keeps the dither
    const float even = 1.0 - smoothstep(0.005, 0.05, abs(next - transmittance));
    const float jitter = (fogDither(gl_FragCoord.xy) - 0.5) * width * even;

    return texture(fogVolume, vec3(uv, clamp(slice + jitter, 0.0, 1.0)));
}

/// A surface colour as the medium and the ground layer leave it
vec3 applyFog(vec3 color, vec3 position)
{
    if(frameUbo.frame.fogParams.x >= 0.5)
    {
        const vec4 fog = sampleFog(position);
        color = color * fog.a + fog.rgb;
    }

    return applyHeightFog(color, position);
}

#endif
