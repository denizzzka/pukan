#version 460

#include "frame.glsl"
#include "section.glsl"

layout(location = 3) in vec3 fragPosition;
layout(location = 0) out vec4 outColor;

// Counts the solid inside the cut shape. The cap is drawn on the far
// surface of that shape where the count is not zero.
void main()
{
    if(sectionParams.z > 1.5)
    {
        const vec3 a = frameUbo.frame.cameraPosition.xyz;
        const vec3 b = sectionShape.xyz;
        const vec3 pa = fragPosition - a;
        const vec3 ba = b - a;
        const float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
        if(length(pa - ba * h) >= sectionShape.w)
            discard;
    }
    else if(sectionParams.z > 0.5)
    {
        const vec3 offset = fragPosition - sectionShape.xyz;
        if(dot(offset, offset) >= sectionShape.w * sectionShape.w)
            discard;
    }
    else if(dot(fragPosition, sectionShape.xyz) + sectionShape.w >= 0.0)
        discard;

    outColor = vec4(0.0);
}
