#include "frame_bindings.h"

/// Fragments the buffer holds; the writer stops linking once it is full
const uint OIT_MAX_FRAGMENTS = 524288u;
/// Head value of a pixel without fragments
const uint OIT_EMPTY = 0xFFFFFFFFu;

struct OitFragment
{
    uint colorLo; /// half2 of red and green
    uint colorHi; /// half2 of blue and alpha
    float depth;
    uint next;
};

layout(set = 1, binding = FRAME_OIT_FRAGMENTS) buffer OitFragments
{
    OitFragment oitFragments[];
};

layout(set = 1, binding = FRAME_OIT_COUNTER) buffer OitCounter
{
    uint oitFragmentCount;
};

#ifdef OIT_READ_ONLY
layout(set = 1, binding = FRAME_OIT_HEADS, r32ui) uniform readonly uimage2D oitHeads;
#else
layout(set = 1, binding = FRAME_OIT_HEADS, r32ui) uniform uimage2D oitHeads;
#endif

#ifndef OIT_READ_ONLY
/// Appends a shaded fragment to the list of its pixel
void oitStoreFragment(vec4 color)
{
    if(color.a <= 0.0)
        return;

    const uint index = atomicAdd(oitFragmentCount, 1u);

    if(index >= OIT_MAX_FRAGMENTS)
        return;

    oitFragments[index].colorLo = packHalf2x16(color.rg);
    oitFragments[index].colorHi = packHalf2x16(color.ba);
    oitFragments[index].depth = gl_FragCoord.z;
    oitFragments[index].next = imageAtomicExchange(oitHeads, ivec2(gl_FragCoord.xy), index);
}
#endif
