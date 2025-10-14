module pukan.gltf;

import dlib.math;
import pukan.vulkan.bindings;
import pukan.vulkan;
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

    {
        const ver = json["asset"]["version"].get!string;
        enforce(ver == "2.0", "glTF version "~ver~" unsupported");
    }

    auto ret = new GlTF;

    Buffer[] buffers;
    foreach(buf; json["buffers"])
        buffers ~= readBufFile(dir, buf);

    View[] bufferViews;
    foreach(v; json["bufferViews"])
    {
        const idx = v["buffer"].get!uint;
        bufferViews ~= buffers[idx].createView(v);
    }

    foreach(a; json["accessors"])
    {
        const idx = a["bufferView"].get!uint;
        ret.accessors ~= bufferViews[idx].createAccessor(a);
    }

    foreach(mesh; json["meshes"])
    {
        Primitive[] primitives;
        foreach(primitive; mesh["primitives"])
        {
            const accessorIdx = primitive["indices"].get!ushort;

            primitives ~= Primitive(
                accessor: &ret.accessors[accessorIdx],
            );
        }

        ret.meshes ~= Mesh(
            name: mesh["name"].opt!string,
            primitives: primitives,
        );
    }

    foreach(node; json["nodes"])
    {
        ushort[] childrenIdxs;
        const children = "children" in node;
        if(children)
            foreach(child; *children)
                childrenIdxs ~= child.get!ushort;

        ret.nodes ~= Node(
            name: node["name"].opt!string,
            childrenNodeIndices: childrenIdxs,
            meshIdx: node["mesh"].opt!short(-1),
        );
    }

    auto scenes = json["scenes"].byValue.array;
    enforce(scenes.length <= 1);

    {
        Json rootScene = scenes[ json["scene"].get!ushort ];

        ret.rootSceneNode.name = rootScene["name"].opt!string;
        ret.rootSceneNode.childrenNodeIndices = rootScene["nodes"]
            .byValue.map!((e) => e.get!ushort)
            .array;
    }

    return ret;
}

struct Buffer
{
    ubyte[] buf;

    View createView(Json view)
    {
        const offset = view["byteOffset"].opt!size_t;

        return View(
            bufSlice: buf[ offset .. offset + view["byteLength"].get!size_t ],
            stride: view["byteStride"].opt!uint,
        );
    }
}

struct View
{
    ubyte[] bufSlice;
    uint stride;

    Accessor createAccessor(Json accessor)
    {
        enforce("sparse" !in accessor);

        const offset = accessor["byteOffset"].opt!size_t;

        return Accessor(
            bufSlice[offset .. $],
            type: accessor["type"].get!string,
            componentType: accessor["componentType"].get!ComponentType,
            count: accessor["count"].get!uint,
        );
    }
}

enum ComponentType : short
{
    BYTE = 5120,
    UNSIGNED_BYTE = 5121,
    SHORT = 5122,
    UNSIGNED_SHORT = 5123,
    UNSIGNED_INT = 5125,
    FLOAT = 5126,
}

struct Accessor
{
    ubyte[] viewSlice;
    string type;
    ComponentType componentType;
    uint count;
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

struct Mesh
{
    string name;
    Primitive[] primitives;
}

struct Primitive
{
    Accessor* accessor;
}

struct Node
{
    string name; /// Not a unique name
    short meshIdx = -1;
    //TODO: store also transformation, rotation, scale matrices, etc
    ushort[] childrenNodeIndices;
}

class GlTF : DrawableByVulkan
{
    //TODO:
    //const {
    Accessor[] accessors;
    Node[] nodes;
    Mesh[] meshes;
    Node rootSceneNode;
    //}

    private TransferBuffer indicesBuffer;

    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        {
            assert(rootSceneNode.childrenNodeIndices.length == 1);
            const node = nodes[ rootSceneNode.childrenNodeIndices[0] ];

            //TODO: just skip such node
            enforce(node.meshIdx >= 0, "mesh index not found");

            const mesh = &meshes[node.meshIdx];
            assert(mesh.primitives.length == 1);

            const primitive = &mesh.primitives[0];

            enforce(primitive.accessor !is null, "non-indexed geometry isn't supported");

            auto indices = primitive.accessor;

            {
                import std.conv: to;

                enforce(indices.type == "SCALAR", indices.type.to!string);
                enforce(indices.componentType == ComponentType.UNSIGNED_SHORT, indices.componentType.to!string);
            }

            assert(indices.count > 0);

            indicesBuffer = device.create!TransferBuffer(ushort.sizeof * indices.count, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);

            // Copy indices to mapped memory
            indicesBuffer.cpuBuf[0..$] = cast(void[]) indices.viewSlice;

            indicesBuffer.uploadImmediate(commandPool, commandBuffer);
        }
    }

    void drawingBufferFilling(VkCommandBuffer buf, GraphicsPipelineCfg pipelineCfg, Matrix4x4f trans)
    {
        //FIXME: implement
    }
}
