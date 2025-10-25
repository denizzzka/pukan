module pukan.misc;

import gamut;
import pukan.exceptions;
import std.conv: to;
import std.exception: enforce;

Image loadImageFromFile(string filepath)
{
    Image image;
    image.loadFromFile(filepath, LAYOUT_GAPLESS|LAYOUT_VERT_STRAIGHT|LOAD_ALPHA);

    check(image);
    return image;
}

Image loadImageFromMemory(const(ubyte)[] blob)
{
    Image image;
    image.loadFromMemory(blob);

    check(image);
    return image;
}

private void check(ref Image image)
{
    if(image.isError)
        throw new PukanException(image.errorMessage.to!string);

    enforce!PukanException(image.type == PixelType.rgba8, "Unsupported texture type: "~image.type.to!string);
    enforce!PukanException(image.layers == 1, "Texture image must contain one layer");
}
