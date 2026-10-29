#version 460

#include "oit.glsl"

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

    uint index = imageLoad(oitHeads, pixel).r;

    for(uint guard = 0u; index != OIT_EMPTY && guard < OIT_MAX_TRAVERSAL; ++guard)
    {
        const OitFragment fragment = oitFragments[index];
        const vec4 color = vec4(
            unpackHalf2x16(fragment.colorLo),
            unpackHalf2x16(fragment.colorHi)
        );

        if(count < OIT_MAX_LAYERS)
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
    float transmittance = 1.0;

    for(uint i = 0u; i < count; ++i)
    {
        premultiplied += transmittance * colors[i].a * colors[i].rgb;
        transmittance *= 1.0 - colors[i].a;
    }

    const float alpha = 1.0 - transmittance;

    if(alpha <= 0.0)
        discard;

    outColor = vec4(premultiplied / alpha, alpha);
}
