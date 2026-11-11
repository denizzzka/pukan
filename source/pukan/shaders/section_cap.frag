#version 460

#include "frame.glsl"

layout(location = 0) in vec2 vNdc;
layout(location = 0) out vec4 outColor;

// The stencil limits this to where the cut surface passes through solid.
// The plane writes its constant depth; the sphere finds the far surface
// along the view ray and writes that depth instead.
void main()
{
    float depth = frameUbo.frame.sectionParams.x;

    if(frameUbo.frame.sectionParams.z > 0.5)
    {
        const vec3 origin = frameUbo.frame.cameraPosition.xyz;
        const vec4 nearPoint = frameUbo.frame.invViewProj * vec4(vNdc, 1.0, 1.0);
        const vec3 direction = normalize(nearPoint.xyz / nearPoint.w - origin);

        const vec3 offset = origin - frameUbo.frame.sectionShape.xyz;
        const float b = dot(offset, direction);
        const float c = dot(offset, offset) - frameUbo.frame.sectionShape.w * frameUbo.frame.sectionShape.w;
        const float h = b * b - c;

        if(h < 0.0)
            discard;

        const float t = -b + sqrt(h);
        if(t < 0.0)
            discard;

        const vec4 clip = frameUbo.frame.viewProj * vec4(origin + direction * t, 1.0);
        depth = clip.z / clip.w;
    }

    gl_FragDepth = depth;

    if(frameUbo.frame.sectionParams.y > 0.5)
    {
        outColor = vec4(0.20, 0.185, 0.17, 1.0);
        return;
    }

    const float stripe = step(0.5, fract((gl_FragCoord.x + gl_FragCoord.y) * 0.125));
    const vec3 color = mix(vec3(0.10, 0.105, 0.11), vec3(0.22, 0.225, 0.23), stripe);
    outColor = vec4(color, 1.0);
}
