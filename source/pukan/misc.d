module pukan.misc;

import pukan.exceptions;
import std.conv: to;
import std.exception: enforce;

auto loadImageFromFile(string filepath)
{
    import gamut;

    Image image;
    image.loadFromFile(filepath, LAYOUT_GAPLESS|LAYOUT_VERT_STRAIGHT|LOAD_ALPHA);

    if(image.isError)
        throw new PukanException(image.errorMessage.to!string);

    enforce!PukanException(image.type == PixelType.rgba8, "Unsupported texture type: "~image.type.to!string);
    enforce!PukanException(image.layers == 1, "Texture image must contain one layer");

    return image;
}
