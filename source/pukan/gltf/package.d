module pukan.gltf;

import std.algorithm;
import std.array;
import std.exception: enforce;
static import std.file;
static import std.path;
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
        enforce(ver == "2.0", "glTF version "~ver~" unsupported");
    }

    const sceneIdx = json["scene"].get!int;
    const scenes = json["scenes"].byValue.array;
    enforce(scenes.length <= 1);

    auto nodesIdxs = scenes[sceneIdx]["nodes"].byValue.map!((e) => e.get!int);
    const nodes = json["nodes"];

    foreach(i; nodesIdxs)
    {
        //~ nodes[i]
    }

    return 0;
}
