#version 460

#include "frame.glsl"

layout(location = 3) in vec3 fragPosition;
layout(location = 0) out vec4 outColor;

// Counts the solid in front of the section plane: the main pass cuts this
// part away, so only its front and back faces contribute to the stencil.
void main()
{
    if(dot(fragPosition, frameUbo.frame.sectionPlane.xyz) + frameUbo.frame.sectionPlane.w >= 0.0)
        discard;

    outColor = vec4(0.0);
}
