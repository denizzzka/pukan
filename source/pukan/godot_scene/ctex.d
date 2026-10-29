module pukan.godot_scene.ctex;

import pukan.compressed_texture.format: CompressedFormat, compressedFormat;
import pukan.exceptions: PukanException;
import pukan.vulkan.bindings: VkFormat, VK_FORMAT_R8_UNORM, VK_FORMAT_R8G8_UNORM,
    VK_FORMAT_R8G8B8_UNORM, VK_FORMAT_R8G8B8_SRGB, VK_FORMAT_R8G8B8A8_UNORM,
    VK_FORMAT_R8G8B8A8_SRGB;
import pukan.webp: decodeWebp;
import std.algorithm: max;
import std.conv: to;

/// One GST2 texture, either a PNG payload, decoded WebP mips or raw/compressed mips
struct GodotCtexImage
{
    uint width;
    uint height;
    const(ubyte)[] png;
    ubyte[][] levels;
    VkFormat format;
    VkFormat srgbFormat;
    bool compressed;
    bool raAsRg;
}

/// Reads a Godot GST2 texture: embedded PNG or WebP, raw and block-compressed mips
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
        result.format = VK_FORMAT_R8G8B8A8_UNORM;
        result.srgbFormat = VK_FORMAT_R8G8B8A8_SRGB;
        return result;
    }

    if(dataFormat == 2)
    {
        result.format = VK_FORMAT_R8G8B8A8_UNORM;
        result.srgbFormat = VK_FORMAT_R8G8B8A8_SRGB;

        foreach(level; 0 .. mipmaps + 1)
        {
            const size = u32();
            ensure(size);

            auto decoded = decodeWebp(data[pos .. pos + size], label);
            result.levels ~= decoded.pixels;
            pos += size;
        }

        return result;
    }

    if(dataFormat != 0)
        throw new PukanException(label ~ ": unsupported ctex data format " ~ dataFormat.to!string);

    if(auto compressed = compressedByGodotFormat(imageFormat))
    {
        result.format = compressed.linear;
        result.srgbFormat = compressed.srgb;
        result.compressed = true;
        result.raAsRg = compressed.raAsRg;

        foreach(level; 0 .. mipmaps + 1)
        {
            const size = compressed.levelSize(result.width, result.height, level);
            ensure(size);
            result.levels ~= cast(ubyte[]) data[pos .. pos + size];
            pos += size;
        }

        return result;
    }

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
            result.format = VK_FORMAT_R8G8B8_UNORM;
            result.srgbFormat = VK_FORMAT_R8G8B8_SRGB;
            components = 3;
            break;

        case 5: // RGBA8
            result.format = VK_FORMAT_R8G8B8A8_UNORM;
            result.srgbFormat = VK_FORMAT_R8G8B8A8_SRGB;
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

/// Whether a sampled format carries only the two normal-map components
bool isTwoChannelNormal(VkFormat format)
{
    import pukan.vulkan.bindings: VK_FORMAT_BC5_UNORM_BLOCK, VK_FORMAT_EAC_R11G11_UNORM_BLOCK,
        VK_FORMAT_EAC_R11G11_SNORM_BLOCK;

    switch(format)
    {
        case VK_FORMAT_BC5_UNORM_BLOCK:
        case VK_FORMAT_EAC_R11G11_UNORM_BLOCK:
        case VK_FORMAT_EAC_R11G11_SNORM_BLOCK:
        case VK_FORMAT_R8G8_UNORM:
            return true;

        default:
            return false;
    }
}

/// Maps a Godot `Image::Format` value to a block-compressed format
private const(CompressedFormat)* compressedByGodotFormat(uint imageFormat)
{
    switch(imageFormat)
    {
        case 17: return compressedFormat("BC1"); // DXT1
        case 18: return compressedFormat("BC2"); // DXT3
        case 19: return compressedFormat("BC3"); // DXT5
        case 20: return compressedFormat("BC4"); // RGTC_R
        case 21: return compressedFormat("BC5"); // RGTC_RG
        case 22: return compressedFormat("BC7"); // BPTC_RGBA
        case 23: return compressedFormat("BC6H_SFLOAT"); // BPTC_RGBF
        case 24: return compressedFormat("BC6H_UFLOAT"); // BPTC_RGBFU
        case 25: return compressedFormat("ETC2_RGB8"); // ETC1 data decodes as ETC2 RGB
        case 26: return compressedFormat("ETC2_R11");
        case 27: return compressedFormat("ETC2_R11S");
        case 28: return compressedFormat("ETC2_RG11");
        case 29: return compressedFormat("ETC2_RG11S");
        case 30: return compressedFormat("ETC2_RGB8");
        case 31: return compressedFormat("ETC2_RGBA8");
        case 32: return compressedFormat("ETC2_RGB8A1");
        case 33: return compressedFormat("ETC2_RA_AS_RG");
        case 34: return compressedFormat("DXT5_RA_AS_RG");
        case 35: return compressedFormat("ASTC_4x4");
        case 36: return compressedFormat("ASTC_4x4_HDR");
        case 37: return compressedFormat("ASTC_8x8");
        case 38: return compressedFormat("ASTC_8x8_HDR");
        default: return null;
    }
}

private string fixturePath(string name)
{
    import std.path: buildPath, dirName;
    return buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "demo", "assets",
        "godot_samples", "generated", name);
}

unittest
{
    import std.file: read;

    const image = loadCtex(cast(const(ubyte)[]) read(fixturePath("checker.ctex")), "checker.ctex");
    assert(image.width == 1024);
    assert(image.height == 1024);
    assert(image.png.length > 0);
    assert(image.png[0] == 0x89 && image.png[1] == 'P' && image.png[2] == 'N' && image.png[3] == 'G');
}

unittest
{
    import std.file: read;
    import pukan.vulkan.bindings: VK_FORMAT_BC1_RGBA_UNORM_BLOCK, VK_FORMAT_BC5_UNORM_BLOCK,
        VK_FORMAT_BC7_UNORM_BLOCK, VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK, VK_FORMAT_ASTC_4x4_UNORM_BLOCK;

    {
        const image = loadCtex(cast(const(ubyte)[]) read(fixturePath("checker.s3tc.ctex")), "s3tc");
        assert(image.compressed);
        assert(image.format == VK_FORMAT_BC1_RGBA_UNORM_BLOCK);
        assert(image.levels.length == 7);
        assert(image.levels[0].length == 16 * 16 * 8);
    }

    {
        const image = loadCtex(cast(const(ubyte)[]) read(fixturePath("checker.bptc.ctex")), "bptc");
        assert(image.compressed);
        assert(image.format == VK_FORMAT_BC7_UNORM_BLOCK);
        assert(image.levels.length == 7);
        assert(image.levels[0].length == 16 * 16 * 16);
    }

    {
        const image = loadCtex(cast(const(ubyte)[]) read(fixturePath("checker.etc2.ctex")), "etc2");
        assert(image.compressed);
        assert(image.format == VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK);
        assert(image.levels.length == 7);
        assert(image.levels[0].length == 16 * 16 * 8);
    }

    {
        const image = loadCtex(cast(const(ubyte)[]) read(fixturePath("checker.astc.ctex")), "astc");
        assert(image.compressed);
        assert(image.format == VK_FORMAT_ASTC_4x4_UNORM_BLOCK);
        assert(image.levels.length == 7);
        assert(image.levels[0].length == 16 * 16 * 16);
    }

    {
        const image = loadCtex(cast(const(ubyte)[]) read(fixturePath("checker_normal.s3tc.ctex")), "bc5");
        assert(image.compressed);
        assert(image.format == VK_FORMAT_BC5_UNORM_BLOCK);
        assert(isTwoChannelNormal(image.format));
    }
}

unittest
{
    import std.file: read;
    import pukan.vulkan.bindings: VK_FORMAT_R8G8B8A8_SRGB, VK_FORMAT_R8G8B8A8_UNORM;

    const image = loadCtex(cast(const(ubyte)[]) read(fixturePath("particle.webp.ctex")), "webp");
    assert(!image.compressed);
    assert(image.width == 16);
    assert(image.height == 16);
    assert(image.format == VK_FORMAT_R8G8B8A8_UNORM);
    assert(image.srgbFormat == VK_FORMAT_R8G8B8A8_SRGB);
    assert(image.levels.length == 1);
    assert(image.levels[0].length == 16 * 16 * 4);
}
