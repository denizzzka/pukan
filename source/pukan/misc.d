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

/// Orthographic projection for Vulkan: Y points down and depth spans [0, 1]
Matrix4x4f vulkanOrthographicMatrix(
    float left,
    float right,
    float bottom,
    float top,
    float nearPlane,
    float farPlane,
)
{
    Matrix4x4f result = Matrix4x4f.identity;

    // A light view looks down -Z, so a positive depth is a negative view z
    result.a11 = 2.0f / (right - left);
    result.a22 = -2.0f / (top - bottom);
    result.a33 = -1.0f / (farPlane - nearPlane);
    result.a14 = -(right + left) / (right - left);
    result.a24 = (top + bottom) / (top - bottom);
    result.a34 = -nearPlane / (farPlane - nearPlane);

    return result;
}

unittest
{
    import std.math: isClose;

    const projection = vulkanOrthographicMatrix(-1, 1, -1, 1, 2, 12);

    const center = Vector4f(0, 0, -7, 1) * projection;
    assert(isClose(center.x, 0, 1e-5f, 1e-5f));
    assert(isClose(center.y, 0, 1e-5f, 1e-5f));
    assert(center.z > 0 && center.z < 1);

    const near = Vector4f(0, 0, -2, 1) * projection;
    assert(isClose(near.z, 0, 1e-5f, 1e-5f));

    const far = Vector4f(0, 0, -12, 1) * projection;
    assert(isClose(far.z, 1, 1e-5f, 1e-5f));

    // Vulkan clip space points Y down
    const top = Vector4f(0, 1, -7, 1) * projection;
    assert(isClose(top.y, -1, 1e-5f, 1e-5f));
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

/// Merges `other` into `box`; a box without bounds takes the other one
void mergeAabb(ref Boxf box, in Boxf other)
{
    import std.math: isNaN;

    if(other.min.x.isNaN)
        return;

    if(box.min.x.isNaN)
    {
        box = other;
        return;
    }

    import std.algorithm: max, min;

    box.min.x = min(box.min.x, other.min.x);
    box.min.y = min(box.min.y, other.min.y);
    box.min.z = min(box.min.z, other.min.z);
    box.max.x = max(box.max.x, other.max.x);
    box.max.y = max(box.max.y, other.max.y);
    box.max.z = max(box.max.z, other.max.z);
}

/// Corners of an axis-aligned box transformed by an affine matrix
Boxf transformAabb(in Boxf box, in Matrix4x4f transform)
{
    import std.math: isNaN;

    if(box.min.x.isNaN)
        return Boxf.init;

    Boxf result;

    foreach(i; 0 .. 8)
    {
        const corner = Vector3f(
            (i & 1) ? box.max.x : box.min.x,
            (i & 2) ? box.max.y : box.min.y,
            (i & 4) ? box.max.z : box.min.z,
        );
        const p = Vector4f(corner.x, corner.y, corner.z, 1) * transform;
        const v = Vector3f(p.x, p.y, p.z);

        if(i == 0)
        {
            result.min = v;
            result.max = v;
        }
        else
            expandAABB(result, v);
    }

    return result;
}
