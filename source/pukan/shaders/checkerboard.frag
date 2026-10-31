#version 460

layout(push_constant) uniform BackgroundData
{
    vec4 top;
    vec4 horizon;
    vec4 groundHorizon;
    vec4 groundBottom;
    vec4 params; // x = mode, y = height, z = energy
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

    outColor = vec4(color, 1.0);
}
