#version 460

layout(location = 0) out vec4 outColor;

void main()
{
    const float cellSize = 16.0;
    vec2 cell = floor(gl_FragCoord.xy / cellSize);
    float odd = mod(cell.x + cell.y, 2.0);
    vec3 color = mix(vec3(0.18), vec3(0.26), odd);

    outColor = vec4(color, 1.0);
}
