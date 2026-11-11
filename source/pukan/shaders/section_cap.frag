#version 460

#include "frame.glsl"

layout(location = 0) out vec4 outColor;

// The stencil limits this to where the cut plane passes through solid
void main()
{
    if(frameUbo.frame.sectionParams.y > 0.5)
    {
        outColor = vec4(0.20, 0.185, 0.17, 1.0);
        return;
    }

    const float stripe = step(0.5, fract((gl_FragCoord.x + gl_FragCoord.y) * 0.125));
    const vec3 color = mix(vec3(0.10, 0.105, 0.11), vec3(0.22, 0.225, 0.23), stripe);
    outColor = vec4(color, 1.0);
}
