module pukan.gltf;

import std.algorithm;
import std.array;
import std.exception: enforce;
debug import std.stdio; //FIXME: remove
static import std.file;
static import std.path;
import vibe.data.json;

///
auto loadGlTF2(string filename)
{
    const json = std.file.readText(filename).parseJsonString;
    const dir = std.path.dirName(filename);

    writeln(filename);
    writeln(dir);

    {
        const ver = json["asset"]["version"].get!string;
        enforce(ver == "2.0", "glTF version "~ver~" unsupported");
    }

    const sceneIdx = json["scene"].get!int;
    const scenes = json["scenes"].byValue.array;
    enforce(scenes.length <= 1);

    Buffer[] buffers;
    foreach(buf; json["buffers"])
    {
        buffers ~= readBufFile(dir, buf);
    }

    auto nodesIdxs = scenes[sceneIdx]["nodes"].byValue.map!((e) => e.get!int);
    const nodes = json["nodes"];

    foreach(i; nodesIdxs)
    {
        //~ nodes[i]
    }

    return 0;
}

struct Buffer
{
    ubyte[] buf;
}

private Buffer readBufFile(string dir, in Json fileDescr)
{
    const len = fileDescr["byteLength"].get!ulong;
    const filename = fileDescr["uri"].get!string;

    Buffer ret;
    ret.buf = cast(ubyte[]) std.file.read(dir ~ std.path.dirSeparator ~ filename);

    enforce(ret.buf.length == len);

    return ret;
}
