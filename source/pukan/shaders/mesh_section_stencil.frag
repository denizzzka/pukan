#version 460

#include "frame.glsl"

layout(location = 3) in vec3 fragPosition;
layout(location = 0) out vec4 outColor;

// Counts the solid inside the cut shape. The cap is drawn on the far
// surface of that shape where the count is not zero.
void main()
{
    if(frameUbo.frame.sectionParams.z > 1.5)
    {
        const vec3 a = frameUbo.frame.cameraPosition.xyz;
        const vec3 b = frameUbo.frame.sectionShape.xyz;
        const vec3 pa = fragPosition - a;
        const vec3 ba = b - a;
        const float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
        if(length(pa - ba * h) >= frameUbo.frame.sectionShape.w)
            discard;
    }
    else if(frameUbo.frame.sectionParams.z > 0.5)
    {
        const vec3 offset = fragPosition - frameUbo.frame.sectionShape.xyz;
        if(dot(offset, offset) >= frameUbo.frame.sectionShape.w * frameUbo.frame.sectionShape.w)
            discard;
    }
    else if(dot(fragPosition, frameUbo.frame.sectionShape.xyz) + frameUbo.frame.sectionShape.w >= 0.0)
        discard;

    outColor = vec4(0.0);
}
