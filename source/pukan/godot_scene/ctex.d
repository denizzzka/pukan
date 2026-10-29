module pukan.godot_scene.ctex;

import pukan.exceptions: PukanException;
import pukan.vulkan.bindings: VkFormat, VK_FORMAT_R8_UNORM, VK_FORMAT_R8G8_UNORM, VK_FORMAT_R8G8B8_SRGB, VK_FORMAT_R8G8B8A8_SRGB;
import std.algorithm: max;
import std.conv: to;

struct GodotCtexImage
{
    uint width;
    uint height;
    const(ubyte)[] png;
    ubyte[][] levels;
    VkFormat format;
}

/// Reads a PNG or raw uncompressed Godot GST2 texture
GodotCtexImage loadCtex(const(ubyte)[] data, string label)
{
    size_t pos;

    void ensure(size_t count)
    {
        if(pos + count > data.length)
            throw new PukanException(label ~ ": unexpected end of ctex");
    }

    uint u32()
    {
        ensure(4);
        const value = cast(uint) data[pos] |
            (cast(uint) data[pos + 1] << 8) |
            (cast(uint) data[pos + 2] << 16) |
            (cast(uint) data[pos + 3] << 24);
        pos += 4;
        return value;
    }

    ushort u16()
    {
        ensure(2);
        const value = cast(ushort) (data[pos] | (data[pos + 1] << 8));
        pos += 2;
        return value;
    }

    ensure(4);
    if(data[0] != 'G' || data[1] != 'S' || data[2] != 'T' || data[3] != '2')
        throw new PukanException(label ~ ": not a GST2 texture");
    pos = 4;

    const formatVersion = u32();
    if(formatVersion > 1)
        throw new PukanException(label ~ ": unsupported ctex version " ~ formatVersion.to!string);

    GodotCtexImage result;
    result.width = u32();
    result.height = u32();
    u32(); // flags
    u32(); // mipmap limit
    u32();
    u32();
    u32();

    const dataFormat = u32();

    u16(); // width
    u16(); // height
    const mipmaps = u32();
    const imageFormat = u32();

    if(dataFormat == 1)
    {
        const size = u32();
        ensure(size);

        auto payload = data[pos .. pos + size];
        // Godot's png_packer prefixes the stream with its own four-byte marker.
        if(payload.length >= 4 && payload[0] == 'P' && payload[1] == 'N' &&
            payload[2] == 'G' && payload[3] == ' ')
            payload = payload[4 .. $];

        result.png = payload;
        return result;
    }

    if(dataFormat != 0)
        throw new PukanException(label ~ ": unsupported ctex data format " ~ dataFormat.to!string);

    uint components;

    switch(imageFormat)
    {
        case 0: // L8
        case 2: // R8
            result.format = VK_FORMAT_R8_UNORM;
            components = 1;
            break;

        case 1: // LA8
        case 3: // RG8
            result.format = VK_FORMAT_R8G8_UNORM;
            components = 2;
            break;

        case 4: // RGB8
            result.format = VK_FORMAT_R8G8B8_SRGB;
            components = 3;
            break;

        case 5: // RGBA8
            result.format = VK_FORMAT_R8G8B8A8_SRGB;
            components = 4;
            break;

        default:
            throw new PukanException(label ~ ": unsupported ctex image format " ~ imageFormat.to!string);
    }

    foreach(level; 0 .. mipmaps + 1)
    {
        const levelWidth = max(result.width >> level, 1u);
        const levelHeight = max(result.height >> level, 1u);
        const size = cast(size_t) levelWidth * levelHeight * components;

        ensure(size);
        result.levels ~= cast(ubyte[]) data[pos .. pos + size];
        pos += size;
    }

    return result;
}

unittest
{
    import std.file: read;
    import std.path: buildPath, dirName;

    const path = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "demo", "assets", "godot_samples", "generated", "checker.ctex");
    const image = loadCtex(cast(const(ubyte)[]) read(path), path);
    assert(image.width == 1024);
    assert(image.height == 1024);
    assert(image.png.length > 0);
    assert(image.png[0] == 0x89 && image.png[1] == 'P' && image.png[2] == 'N' && image.png[3] == 'G');
}
