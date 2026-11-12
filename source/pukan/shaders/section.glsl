// Push constants the section pipelines carry after the model matrix. The cap
// has no model matrix, so it includes this with its own offset.
#ifndef SECTION_PUSH_OFFSET
#define SECTION_PUSH_OFFSET 64
#endif

layout(push_constant) uniform SectionPush
{
    // plane: xyz = normal, w = -dot(point, normal); sphere and capsule: xyz = centre, w = radius
    layout(offset = SECTION_PUSH_OFFSET) vec4 sectionShape;
    // x = plane NDC depth, y = fill (0 hatch, 1 colour), z = shape (0 plane, 1 sphere, 2 capsule)
    layout(offset = SECTION_PUSH_OFFSET + 16) vec4 sectionParams;
};
