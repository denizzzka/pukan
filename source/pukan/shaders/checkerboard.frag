#version 460

#include "tonemap.glsl"
#include "frame.glsl"
#include "fog_volume.glsl"

layout(push_constant) uniform BackgroundData
{
    vec4 top;
    vec4 horizon;
    vec4 groundHorizon;
    vec4 groundBottom;
    vec4 params; // x = mode, y = height, z = energy
    vec4 tonemap; // x = mode, y = white, z = exposure
};

layout(location = 0) out vec4 outColor;

void main()
{
    const uint mode = uint(params.x);
    vec3 color;

    if(mode == 0u)
    {
        const float cellSize = 16.0;
        vec2 cell = floor(gl_FragCoord.xy / cellSize);
        float odd = mod(cell.x + cell.y, 2.0);
        color = mix(vec3(0.18), vec3(0.26), odd);
    }
    else if(mode == 1u)
        color = horizon.rgb * params.z;
    else
    {
        const float t = 1.0 - gl_FragCoord.y / params.y;

        if(t > 0.5)
            color = mix(horizon.rgb, top.rgb, smoothstep(0.5, 1.0, t));
        else if(t > 0.25)
            color = mix(groundHorizon.rgb, horizon.rgb, smoothstep(0.25, 0.5, t));
        else
            color = mix(groundBottom.rgb, groundHorizon.rgb, smoothstep(0.0, 0.25, t));

        color *= params.z;
    }

    // The sky sits at the fog's length, the far edge of the medium, so the
    // accumulated ray already covers all the fog in front of it
    if(frameUbo.frame.fogParams.x >= 0.5)
    {
        const vec2 uv = gl_FragCoord.xy * frameUbo.frame.fogScreen.xy;
        const vec4 fog = texture(fogVolume, vec3(uv, 1.0));
        const vec3 covered = color * fog.a + fog.rgb;

        color = mix(color, covered, clamp(frameUbo.frame.fogEmission.a, 0.0, 1.0));
    }

    color *= tonemap.z;
    color = toneMap(color, uint(tonemap.x), tonemap.y);
    outColor = vec4(color, 1.0);
}
