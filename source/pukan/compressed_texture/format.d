module pukan.compressed_texture.format;

import pukan.vulkan.bindings;
import std.algorithm: max;

/// Block-compressed texture families Godot can store in a `.ctex`
enum CompressedFamily
{
    bc,
    etc2,
    astc,
}

/// One block-compressed Vulkan format and its mip layout
struct CompressedFormat
{
    string name;
    CompressedFamily family;
    uint blockWidth = 4;
    uint blockHeight = 4;
    uint blockBytes;
    VkFormat linear;
    VkFormat srgb;
    bool hdr;
    /// Godot's RA_AS_RG normal-map swizzle
    bool raAsRg;

    /// Vulkan format for the requested color space
    VkFormat vkFormat(bool srgbColor) const
    {
        return srgbColor && srgb != VK_FORMAT_UNDEFINED ? srgb : linear;
    }

    /// Bytes in one mip level of a two-dimensional image
    size_t levelSize(uint width, uint height, uint level = 0) const
    {
        const levelWidth = max(width >> level, 1u);
        const levelHeight = max(height >> level, 1u);
        const blocksX = (levelWidth + blockWidth - 1) / blockWidth;
        const blocksY = (levelHeight + blockHeight - 1) / blockHeight;
        return cast(size_t) blocksX * blocksY * blockBytes;
    }
}

private CompressedFormat bc(string name, uint blockBytes, VkFormat linear, VkFormat srgb,
    bool raAsRg = false)
{
    return CompressedFormat(name, CompressedFamily.bc, 4, 4, blockBytes, linear, srgb, false, raAsRg);
}

private CompressedFormat etc2(string name, uint blockBytes, VkFormat linear, VkFormat srgb,
    bool raAsRg = false)
{
    return CompressedFormat(name, CompressedFamily.etc2, 4, 4, blockBytes, linear, srgb, false, raAsRg);
}

private CompressedFormat astc(string name, uint blockWidth, uint blockHeight, VkFormat linear,
    VkFormat srgb, bool hdr)
{
    return CompressedFormat(name, CompressedFamily.astc, blockWidth, blockHeight, 16, linear, srgb, hdr);
}

/// Formats mapped from Godot's `Image::Format` values
immutable CompressedFormat[] compressedFormats = [
    bc("BC1", 8, VK_FORMAT_BC1_RGBA_UNORM_BLOCK, VK_FORMAT_BC1_RGBA_SRGB_BLOCK),
    bc("BC2", 16, VK_FORMAT_BC2_UNORM_BLOCK, VK_FORMAT_BC2_SRGB_BLOCK),
    bc("BC3", 16, VK_FORMAT_BC3_UNORM_BLOCK, VK_FORMAT_BC3_SRGB_BLOCK),
    bc("BC4", 8, VK_FORMAT_BC4_UNORM_BLOCK, VK_FORMAT_UNDEFINED),
    bc("BC5", 16, VK_FORMAT_BC5_UNORM_BLOCK, VK_FORMAT_UNDEFINED),
    bc("BC6H_UFLOAT", 16, VK_FORMAT_BC6H_UFLOAT_BLOCK, VK_FORMAT_UNDEFINED),
    bc("BC6H_SFLOAT", 16, VK_FORMAT_BC6H_SFLOAT_BLOCK, VK_FORMAT_UNDEFINED),
    bc("BC7", 16, VK_FORMAT_BC7_UNORM_BLOCK, VK_FORMAT_BC7_SRGB_BLOCK),
    etc2("ETC2_R11", 8, VK_FORMAT_EAC_R11_UNORM_BLOCK, VK_FORMAT_UNDEFINED),
    etc2("ETC2_R11S", 8, VK_FORMAT_EAC_R11_SNORM_BLOCK, VK_FORMAT_UNDEFINED),
    etc2("ETC2_RG11", 16, VK_FORMAT_EAC_R11G11_UNORM_BLOCK, VK_FORMAT_UNDEFINED),
    etc2("ETC2_RG11S", 16, VK_FORMAT_EAC_R11G11_SNORM_BLOCK, VK_FORMAT_UNDEFINED),
    etc2("ETC2_RGB8", 8, VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK, VK_FORMAT_ETC2_R8G8B8_SRGB_BLOCK),
    etc2("ETC2_RGBA8", 16, VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK, VK_FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK),
    etc2("ETC2_RGB8A1", 8, VK_FORMAT_ETC2_R8G8B8A1_UNORM_BLOCK, VK_FORMAT_ETC2_R8G8B8A1_SRGB_BLOCK),
    etc2("ETC2_RA_AS_RG", 16, VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK,
        VK_FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK, true),
    bc("DXT5_RA_AS_RG", 16, VK_FORMAT_BC3_UNORM_BLOCK, VK_FORMAT_BC3_SRGB_BLOCK, true),
    astc("ASTC_4x4", 4, 4, VK_FORMAT_ASTC_4x4_UNORM_BLOCK, VK_FORMAT_ASTC_4x4_SRGB_BLOCK, false),
    astc("ASTC_4x4_HDR", 4, 4, VK_FORMAT_ASTC_4x4_SFLOAT_BLOCK_EXT, VK_FORMAT_UNDEFINED, true),
    astc("ASTC_8x8", 8, 8, VK_FORMAT_ASTC_8x8_UNORM_BLOCK, VK_FORMAT_ASTC_8x8_SRGB_BLOCK, false),
    astc("ASTC_8x8_HDR", 8, 8, VK_FORMAT_ASTC_8x8_SFLOAT_BLOCK_EXT, VK_FORMAT_UNDEFINED, true),
];

/// Lookup by the short name used in this package
const(CompressedFormat)* compressedFormat(string name)
{
    foreach(ref format; compressedFormats)
        if(format.name == name)
            return &format;

    return null;
}

/// Lookup by either the linear or the sRGB Vulkan format
const(CompressedFormat)* compressedFormat(VkFormat format)
{
    foreach(ref candidate; compressedFormats)
        if(candidate.linear == format || candidate.srgb == format)
            return &candidate;

    return null;
}

/// Remap key Godot uses for a compressed family
CompressedFamily remapFamily(string key)
{
    switch(key)
    {
        case "s3tc":
        case "bptc":
            return CompressedFamily.bc;

        case "etc2":
            return CompressedFamily.etc2;

        case "astc":
        case "mobile":
            return CompressedFamily.astc;

        default:
            assert(0, "unknown compressed remap key: " ~ key);
    }
}

/// Number of mip levels for a full chain
uint compressedMipCount(uint width, uint height)
{
    uint levels = 1;

    while(width > 1 || height > 1)
    {
        width = max(width >> 1, 1u);
        height = max(height >> 1, 1u);
        ++levels;
    }

    return levels;
}

unittest
{
    assert(compressedMipCount(1024, 512) == 11);
    assert(compressedMipCount(1, 1) == 1);
    assert(compressedMipCount(3, 5) == 3);

    auto bc1 = compressedFormat("BC1");
    assert(bc1 !is null);
    assert(bc1.blockBytes == 8);
    assert(bc1.levelSize(4, 4) == 8);
    assert(bc1.levelSize(1024, 512) == 256 * 128 * 8);
    assert(bc1.levelSize(1024, 512, 1) == 128 * 64 * 8);
    assert(bc1.levelSize(1, 1) == 8);
    assert(bc1.vkFormat(false) == VK_FORMAT_BC1_RGBA_UNORM_BLOCK);
    assert(bc1.vkFormat(true) == VK_FORMAT_BC1_RGBA_SRGB_BLOCK);

    auto bc4 = compressedFormat("BC4");
    assert(bc4 !is null);
    assert(bc4.vkFormat(true) == VK_FORMAT_BC4_UNORM_BLOCK);

    auto astc = compressedFormat("ASTC_8x8");
    assert(astc !is null);
    assert(astc.levelSize(8, 8) == 16);
    assert(astc.levelSize(1024, 512) == 128 * 64 * 16);

    auto ra = compressedFormat("DXT5_RA_AS_RG");
    assert(ra !is null);
    assert(ra.raAsRg);
    assert(ra.vkFormat(true) == VK_FORMAT_BC3_SRGB_BLOCK);

    assert(remapFamily("s3tc") == CompressedFamily.bc);
    assert(remapFamily("bptc") == CompressedFamily.bc);
    assert(remapFamily("etc2") == CompressedFamily.etc2);
    assert(remapFamily("astc") == CompressedFamily.astc);
    assert(remapFamily("mobile") == CompressedFamily.astc);
}
