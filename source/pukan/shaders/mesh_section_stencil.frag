#version 460

#include "frame.glsl"

layout(location = 3) in vec3 fragPosition;
layout(location = 0) out vec4 outColor;

// Counts the solid up to the cut surface. The plane keeps its near part;
// the sphere keeps whatever the depth test against the sphere surface
// lets through, which counts the solid up to that surface.
void main()
{
    if(frameUbo.frame.sectionParams.z <= 0.5)
    {
        if(dot(fragPosition, frameUbo.frame.sectionShape.xyz) + frameUbo.frame.sectionShape.w >= 0.0)
            discard;
    }

    outColor = vec4(0.0);
}
