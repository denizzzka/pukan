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
