module pukan.webp;

import pukan.exceptions: PukanException;
import std.conv: to;

import pukan.webp_bindings;

/// Decoded RGBA8 WebP pixels
struct WebpImage
{
    uint width;
    uint height;
    ubyte[] pixels;
}

private bool webpSize(const(ubyte)[] data, out uint width, out uint height) @nogc nothrow
{
    int decodedWidth;
    int decodedHeight;

    if(WebPGetInfo(data.ptr, data.length, &decodedWidth, &decodedHeight) == 0 ||
        decodedWidth <= 0 || decodedHeight <= 0)
        return false;

    width = cast(uint) decodedWidth;
    height = cast(uint) decodedHeight;
    return true;
}

/// Decodes into a caller-provided RGBA8 buffer
bool decodeWebpInto(
    const(ubyte)[] data,
    ubyte[] pixels,
    out uint width,
    out uint height,
) @nogc nothrow
{
    if(!webpSize(data, width, height))
        return false;

    if(pixels.length < cast(size_t) width * height * 4)
        return false;

    if(WebPDecodeRGBAInto(data.ptr, data.length, pixels.ptr, pixels.length, width * 4) is null)
        return false;

    return true;
}

/// Decodes a complete WebP bitstream, allocating the RGBA8 pixels
WebpImage decodeWebp(const(ubyte)[] data, string label = "webp")
{
    uint width;
    uint height;

    if(!webpSize(data, width, height))
        throw new PukanException(label ~ ": not a WebP image");

    auto pixels = new ubyte[cast(size_t) width * height * 4];

    if(!decodeWebpInto(data, pixels, width, height))
        throw new PukanException(label ~ ": WebP decoding failed");

    return WebpImage(width, height, pixels);
}

unittest
{
    import std.file: read;
    import std.path: buildPath, dirName;

    const path = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "demo_godot",
        "godot_samples", "platformer", "particle.webp");
    const data = cast(const(ubyte)[]) read(path);

    const image = decodeWebp(data, path);
    assert(image.width == 16);
    assert(image.height == 16);
    assert(image.pixels.length == 16 * 16 * 4);

    ubyte[] pixels = new ubyte[16 * 16 * 4];
    uint width;
    uint height;
    assert(decodeWebpInto(data, pixels, width, height));
    assert(width == 16);
    assert(height == 16);
    assert(pixels == image.pixels);
}
