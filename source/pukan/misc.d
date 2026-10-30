module pukan.misc;

import gamut;
import pukan.exceptions;
import pukan.vulkan.bindings: VkFormat;
import pukan.webp: decodeWebp;
import std.conv: to;
import std.exception: enforce;

Image loadImageFromFile(string filepath, out VkFormat format)
{
    import std.file: read;

    Image image;

    // gamut cannot read WebP, so these files are decoded before it sees them
    if(isWebp(cast(const(ubyte)[]) read(filepath, 12)))
        webpImage(cast(const(ubyte)[]) read(filepath), image, format);
    else
    {
        image.loadFromFile(filepath, LAYOUT_GAPLESS|LAYOUT_VERT_STRAIGHT|LOAD_ALPHA);
        check(image, format);
    }

    return image;
}

Image loadImageFromMemory(const(ubyte)[] blob, out VkFormat format)
{
    Image image;

    if(isWebp(blob))
        webpImage(blob, image, format);
    else
    {
        image.loadFromMemory(blob, LAYOUT_GAPLESS|LAYOUT_VERT_STRAIGHT|LOAD_ALPHA);
        check(image, format);
    }

    return image;
}

private bool isWebp(const(ubyte)[] blob) nothrow @nogc
{
    return blob.length >= 12
        && blob[0 .. 4] == "RIFF"
        && blob[8 .. 12] == "WEBP";
}

private void webpImage(const(ubyte)[] blob, ref Image image, out VkFormat format)
{
    const webp = decodeWebp(blob);

    image.create(webp.width, webp.height, PixelType.rgba8, LAYOUT_GAPLESS|LAYOUT_VERT_STRAIGHT);
    image.allPixelsAtOnce()[] = webp.pixels[];

    with(VkFormat)
        format = VK_FORMAT_R8G8B8A8_SRGB;
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

unittest
{
    import std.file: read;
    import std.path: buildPath, dirName;

    const path = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "demo_godot",
        "godot_samples", "platformer", "particle.webp");

    VkFormat format;
    const image = loadImageFromFile(path, format);
    with(VkFormat)
        assert(format == VK_FORMAT_R8G8B8A8_SRGB);
    assert(image.width == 16 && image.height == 16);

    const blob = cast(const(ubyte)[]) read(path);
    const fromMemory = loadImageFromMemory(blob, format);
    with(VkFormat)
        assert(format == VK_FORMAT_R8G8B8A8_SRGB);
    assert(fromMemory.width == 16 && fromMemory.height == 16);
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

import dlib.math: Matrix4x4f, Vector3f, Vector4f, translationMatrix;

//TODO: try dlib.geometry.aabb.AABB instead: it provides intersectsAABB and
// closestPoint, but has no comparison for two boxes
struct Boxf
{
    Vector3f min;
    Vector3f max;
}

/// Conservative clip-space test; a box without bounds is always visible
bool isVisible(in Boxf box, in Matrix4x4f mvp) @safe nothrow pure
{
    import std.math: abs, isNaN;

    foreach(axis; 0 .. 3)
        if(box.min[axis].isNaN || box.max[axis].isNaN)
            return true;

    const center = (box.min + box.max) * 0.5f;
    const extent = (box.max - box.min) * 0.5f;

    // `v * mvp` is the row vector times the matrix, so each clip coordinate
    // is the dot of the vertex with one matrix row
    Vector4f row(size_t index) @safe nothrow pure
    {
        return Vector4f(
            mvp.arrayof[index],
            mvp.arrayof[4 + index],
            mvp.arrayof[8 + index],
            mvp.arrayof[12 + index],
        );
    }

    bool outside(Vector4f p) @safe nothrow pure
    {
        const distance = p.x * center.x + p.y * center.y + p.z * center.z + p.w
            + abs(p.x) * extent.x + abs(p.y) * extent.y + abs(p.z) * extent.z;

        return distance < 0.0f;
    }

    const w = row(3);

    foreach(axis; 0 .. 3)
    {
        const axisRow = row(axis);

        if(outside(axisRow + w) || outside(w - axisRow))
            return false;
    }

    return true;
}

unittest
{
    const unit = Boxf(Vector3f(0, 0, 0), Vector3f(1, 1, 1));

    assert(isVisible(unit, Matrix4x4f.identity));
    assert(!isVisible(Boxf(Vector3f(2, 0, 0), Vector3f(3, 1, 1)), Matrix4x4f.identity));
    assert(!isVisible(Boxf(Vector3f(0, -3, 0), Vector3f(1, -2, 1)), Matrix4x4f.identity));

    // Rows carry the clip planes, so a translation reaches them
    assert(!isVisible(unit, Vector3f(100, 0, 0).translationMatrix));
    assert(isVisible(unit, Vector3f(-0.5f, 0, 0).translationMatrix));

    Boxf unknown;
    assert(isVisible(unknown, Matrix4x4f.identity));
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
