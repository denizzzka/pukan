#version 460

#include "frame.glsl"

void main()
{
    // Fullscreen triangle at the section plane's depth
    const vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(p * 2.0 - 1.0, frameUbo.frame.sectionParams.x, 1.0);
}
