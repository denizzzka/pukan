#version 460

#include "frame.glsl"

layout(location = 0) in vec2 vNdc;
layout(location = 0) out vec4 outColor;

// The stencil limits this to where the cut shape contains solid. The plane
// writes a constant depth, the sphere its far surface, and the capsule the
// first boundary along the view ray.
void main()
{
    const vec3 origin = frameUbo.frame.cameraPosition.xyz;
    const vec4 nearPoint = frameUbo.frame.invViewProj * vec4(vNdc, 1.0, 1.0);
    const vec3 direction = normalize(nearPoint.xyz / nearPoint.w - origin);

    float depth = frameUbo.frame.sectionParams.x;

    if(frameUbo.frame.sectionParams.z > 1.5)
    {
        const vec3 b = frameUbo.frame.sectionShape.xyz;
        const float radius = frameUbo.frame.sectionShape.w;
        const vec3 ba = b - origin;
        const float lengthBA = length(ba);
        const vec3 axis = ba / max(lengthBA, 1e-6);
        const vec3 dPerp = direction - axis * dot(direction, axis);
        const float A = dot(dPerp, dPerp);
        const float tCyl = A > 1e-6 ? radius / sqrt(A) : -1.0;
        const float axial = dot(direction * tCyl, axis);
        const bool cylValid = tCyl > 0.0 && axial >= 0.0 && axial <= lengthBA;
        float t = cylValid ? tCyl : -1.0;

        const vec3 oc = -ba;
        const float bq = dot(oc, direction);
        const float cq = dot(oc, oc) - radius * radius;
        const float hq = bq * bq - cq;
        const float tSphere = hq >= 0.0 ? -bq + sqrt(hq) : -1.0;
        if(tSphere > 0.0 && (t < 0.0 || tSphere < t))
            t = tSphere;

        if(t < 0.0)
            discard;

        const vec4 clip = frameUbo.frame.viewProj * vec4(origin + direction * t, 1.0);
        depth = clip.z / clip.w;
    }
    else if(frameUbo.frame.sectionParams.z > 0.5)
    {
        const vec3 oc = origin - frameUbo.frame.sectionShape.xyz;
        const float bq = dot(oc, direction);
        const float cq = dot(oc, oc) - frameUbo.frame.sectionShape.w * frameUbo.frame.sectionShape.w;
        const float hq = bq * bq - cq;

        if(hq < 0.0)
            discard;

        const float t = -bq + sqrt(hq);
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
