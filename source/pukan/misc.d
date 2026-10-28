module pukan.misc;

import gamut;
import pukan.exceptions;
import pukan.vulkan.bindings: VkFormat;
import std.conv: to;
import std.exception: enforce;

Image loadImageFromFile(string filepath, out VkFormat format)
{
    Image image;
    image.loadFromFile(filepath, LAYOUT_GAPLESS|LAYOUT_VERT_STRAIGHT|LOAD_ALPHA);

    check(image, format);
    return image;
}

Image loadImageFromMemory(const(ubyte)[] blob, out VkFormat format)
{
    Image image;
    image.loadFromMemory(blob, LAYOUT_GAPLESS|LAYOUT_VERT_STRAIGHT|LOAD_ALPHA);

    check(image, format);
    return image;
}

private void check(ref Image image, out VkFormat format)
{
    if(image.isError)
        throw new PukanException(image.errorMessage.to!string);

    enforce!PukanException(image.layers == 1, "Texture image must contain one layer");

    with(PixelType)
    with(VkFormat)
    switch(image.type)
    {
        case rgba8:
            format = VK_FORMAT_R8G8B8A8_SRGB;
            break;

        case rgb8:
            format = VK_FORMAT_R8G8B8_SRGB;
            break;

        default:
            enforce!PukanException(false, "Unsupported texture type: "~image.type.to!string);
    }
}

/// Same texel layout, but sampled without the sRGB transfer function
VkFormat linearFormat(VkFormat format) @safe nothrow pure
{
    switch(format)
    {
        case VkFormat.VK_FORMAT_R8G8B8A8_SRGB: return VkFormat.VK_FORMAT_R8G8B8A8_UNORM;
        case VkFormat.VK_FORMAT_R8G8B8_SRGB: return VkFormat.VK_FORMAT_R8G8B8_UNORM;
        default: return format;
    }
}

import dlib.math: Vector3f;

//TODO: try dlib.geometry.aabb.AABB instead: it provides intersectsAABB and
// closestPoint, but has no comparison for two boxes
struct Boxf
{
    Vector3f min;
    Vector3f max;
}

void expandAABB(ref Boxf box, in Vector3f v)
{
    if(v.x < box.min.x) box.min.x = v.x;
    else
    if(v.x > box.max.x) box.max.x = v.x;

    if(v.y < box.min.y) box.min.y = v.y;
    else
    if(v.y > box.max.y) box.max.y = v.y;

    if(v.z < box.min.z) box.min.z = v.z;
    else
    if(v.z > box.max.z) box.max.z = v.z;
}
