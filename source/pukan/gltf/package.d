module pukan.gltf;

import std.exception: enforce;
static import std.file;
static import std.path;
import pukan.exceptions;
import vibe.data.json;

///
auto loadGlTF2(string filename)
{
    const json = std.file.readText(filename).parseJsonString;
    const dir = std.path.dirName(filename);

    import std.stdio;
    writeln(filename);
    writeln(dir);

    {
        const ver = json["asset"]["version"].get!string;
        enforce!PukanException(ver == "2.0", "glTF version "~ver~" unsupported");
    }

    return 0;
}
