#version 460

#include "oit.glsl"

layout(set = 1, binding = FRAME_SCENE_DEPTH) uniform sampler2D sceneDepthMap;

layout(push_constant) uniform Push
{
    /// Non-zero while only fragments in front of the scene depth are composited
    uint filterDepth;
} push;

layout(location = 0) out vec4 outColor;

/// Layers kept per pixel; a deeper stack drops its furthest fragments
const uint OIT_MAX_LAYERS = 32u;
/// Guards against a corrupt or cyclic list
const uint OIT_MAX_TRAVERSAL = 1024u;

void main()
{
    const ivec2 pixel = ivec2(gl_FragCoord.xy);

    float depths[OIT_MAX_LAYERS];
    vec4 colors[OIT_MAX_LAYERS];
    uint count = 0u;

    const float reference = push.filterDepth != 0u
        ? texelFetch(sceneDepthMap, pixel, 0).r
        : 1.0;

    uint index = imageLoad(oitHeads, pixel).r;

    for(uint guard = 0u; index != OIT_EMPTY && guard < OIT_MAX_TRAVERSAL; ++guard)
    {
        const OitFragment fragment = oitFragments[index];
        const vec4 color = vec4(
            unpackHalf2x16(fragment.colorLo),
            unpackHalf2x16(fragment.colorHi)
        );

        if(count < OIT_MAX_LAYERS && fragment.depth <= reference + 1e-5)
        {
            // Insertion sort, far to near
            uint at = count;

            while(at > 0u && depths[at - 1u] < fragment.depth)
            {
                depths[at] = depths[at - 1u];
                colors[at] = colors[at - 1u];
                --at;
            }

            depths[at] = fragment.depth;
            colors[at] = color;
            ++count;
        }

        index = fragment.next;
    }

    if(count == 0u)
        discard;

    vec3 premultiplied = vec3(0.0);
    float alpha = 0.0;

    // Far to near: each layer paints over everything already composited
    for(uint i = 0u; i < count; ++i)
    {
        const float a = colors[i].a;
        premultiplied = a * colors[i].rgb + (1.0 - a) * premultiplied;
        alpha = a + (1.0 - a) * alpha;
    }

    if(alpha <= 0.0)
        discard;

    outColor = vec4(premultiplied / alpha, alpha);
}
