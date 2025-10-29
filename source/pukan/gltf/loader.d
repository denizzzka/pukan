module pukan.gltf.loader;

import dlib.math;
import pukan.gltf: GlTF;
import pukan.vulkan.bindings;
import pukan.vulkan;
import std.algorithm;
import std.array;
import std.exception: enforce;
static import std.file;
static import std.path;
import vibe.data.json;

private struct Header
{
    uint magic;
    uint ver;
    uint length;

    bool isBinaryFile() const
    {
        return magic == 0x46546C67 && ver == 2;
    }
}

private auto readGltfFile(string filename)
{
    const fileContent = std.file.read(filename);
    enforce(fileContent.length > 12);

    const header = cast(Header*) &fileContent[0];

    static struct Result
    {
        Json json;
        ubyte[] buffer;
    }

    Result ret;
    const(void)[] jsonText;

    if(!header.isBinaryFile)
        jsonText = fileContent;
    else
    {
        enforce(fileContent.length == header.length);

        size_t curr = Header.sizeof;
        const jsonHdr = cast(ChunkHeader*) &fileContent[curr];
        enforce(jsonHdr.isJson);

        curr += ChunkHeader.sizeof;
        jsonText = fileContent[curr .. curr + jsonHdr.chunkLength];

        curr += jsonHdr.chunkLength;
        const binHdr = cast(ChunkHeader*) &fileContent[curr];
        enforce(!binHdr.isJson);

        curr += ChunkHeader.sizeof;
        ret.buffer = cast(ubyte[]) fileContent[curr .. curr + binHdr.chunkLength];
    }

    ret.json = (cast(string) jsonText).parseJsonString;

    return ret;
}

private struct ChunkHeader
{
    uint chunkLength;
    uint chunkType;

    bool isJson() const
    {
        switch(chunkType)
        {
            case 0x4E4F534A: return true; // Structured JSON content
            case 0x004E4942: return false; // Binary buffer
            default: enforce(false, "unknown chunk type");
        }

        assert(0);
    }
}

///
package auto loadGlTF2(string filename, PoolAndLayoutInfo poolAndLayout, LogicalDevice device, ref GraphicsPipelineCfg pipeline)
{
    auto gltfFile = readGltfFile(filename);
    const json = gltfFile.json;
    const dir = std.path.dirName(filename);

    {
        const ver = json["asset"]["version"].get!string;
        enforce(ver == "2.0", "glTF version "~ver~" unsupported");
    }

    Buffer[] buffers;
    GltfContent ret;
    Node[] nodes;
    Node rootSceneNode;

    if(gltfFile.buffer)
        buffers ~= Buffer(buf: gltfFile.buffer);
    else
        foreach(buf; json["buffers"])
            buffers ~= readBufFile(dir, buf);

    foreach(v; json["bufferViews"])
    {
        const idx = v["buffer"].get!uint;
        ret.bufferViews ~= buffers[idx].createView(idx, v);
    }

    foreach(a; json["accessors"])
    {
        const idx = a["bufferView"].get!uint;
        ret.accessors ~= ret.bufferViews[idx].createAccessor(idx, a);
    }

    foreach(mesh; json["meshes"])
    {
        Primitive[] primitives;
        foreach(primitive; mesh["primitives"])
        {
            enforce(primitive["mode"].opt!ushort(4) == 4, "only supported mode = 4 (TRIANGLES)");
            const indicesAccessorIdx = primitive["indices"].opt!int(-1);

            primitives ~= Primitive(
                indicesAccessorIdx: indicesAccessorIdx,
                attributes: primitive["attributes"],
                material: primitive["material"],
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

        import dlib.math;

        Matrix4x4f trans;
        {
            Vector3f tr;
            Quaternionf rot;
            Vector3f scale;

            {
                auto json = "translation" in node;
                if(json is null)
                    tr = Vector3f(0, 0, 0);
                else
                {
                    auto a = (*json).deserializeJson!(float[3]);
                    tr = Vector3f(a[0], a[1], a[2]);
                }
            }

            {
                auto json = "rotation" in node;
                if(json is null)
                    rot = Quaternionf.identity;
                else
                {
                    auto a = (*json).deserializeJson!(float[4]);
                    rot = Quaternionf(Vector4f(a[0], a[1], a[2], a[3]));
                }
            }

            {
                auto json = "scale" in node;
                if(json is null)
                    scale = Vector3f(1, 1, 1);
                else
                {
                    auto a = (*json).deserializeJson!(float[3]);
                    scale = Vector3f(a[0], a[1], a[2]);
                }
            }

            trans = tr.translationMatrix * rot.toMatrix4x4 * scale.scaleMatrix;
        }

        nodes ~= Node(
            childrenNodeIndices: childrenIdxs,
            payload: NodePayload(
                name: node["name"].opt!string,
                meshIdx: node["mesh"].opt!int(-1),
                trans: trans,
            ),
        );
    }

    auto scenes = json["scenes"].byValue.array;
    enforce(scenes.length == 1);

    {
        Json rootScene = scenes[ json["scene"].opt!ushort(0) ];

        rootSceneNode.name = rootScene["name"].opt!string;
        rootSceneNode.trans = Matrix4x4f.identity;
        rootSceneNode.childrenNodeIndices = rootScene["nodes"]
            .byValue.map!((e) => e.get!ushort)
            .array;
    }

    scope commandPool = device.createCommandPool();
    scope commandBufs = commandPool.allocateBuffers(1);
    scope(exit) commandPool.freeBuffers(commandBufs);

    auto images = "images" in json;
    if(images)
        foreach(ref img; *images) //FIXME: indent
    {
        const viewIdxPtr = "bufferView" in img;

        import pukan.misc: loadImageFromFile, loadImageFromMemory;
        import std.traits: ReturnType;

        ReturnType!loadImageFromMemory extFormatImg;
        VkFormat format;

        if(viewIdxPtr !is null)
        {
            const mime = "mimeType" in img;
            enforce(mime);
            enforce(
                mime.get!string == "image/jpeg" || mime.get!string == "image/png",
                (*mime).to!string
            );

            const View view = ret.bufferViews[viewIdxPtr.get!ushort];

            extFormatImg = loadImageFromMemory(view.buf, format);
        }
        else
            extFormatImg = loadImageFromFile(build_path(dir, img["uri"].get!string), format);

        ret.images ~= loadImageToMemory(device, commandPool, commandBufs[0], extFormatImg, format);
    }

    //FIXME: implement samplers reading

    auto textures = "textures" in json;
    if(textures) foreach(tx; *textures)
    {
        VkSamplerCreateInfo defaultSampler = {
            sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            magFilter: VK_FILTER_LINEAR,
            minFilter: VK_FILTER_LINEAR,
            addressModeU: VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
            addressModeV: VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
            addressModeW: VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
            anisotropyEnable: VK_TRUE,
            maxAnisotropy: 16, //TODO: use vkGetPhysicalDeviceProperties (at least)
            borderColor: VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            unnormalizedCoordinates: VK_FALSE,
            compareEnable: VK_FALSE,
            compareOp: VK_COMPARE_OP_ALWAYS,
            mipmapMode: VK_SAMPLER_MIPMAP_MODE_LINEAR,
        };

        auto image = ret.images[ tx["source"].get!ushort ];
        //FIXME: use samplers[]
        ret.textures ~= device.create!Texture(image, defaultSampler);
    }

    return new GlTF(pipeline, poolAndLayout, device, ret, nodes, rootSceneNode);
}

struct Buffer
{
    ubyte[] buf;

    View createView(size_t idx, Json view)
    {
        return View(
            buffer: buf,
            length: view["byteLength"].get!uint,
            offset: view["byteOffset"].opt!uint,
            stride: view["byteStride"].opt!ubyte,
        );
    }
}

struct View
{
    const ubyte[] buf;
    const ubyte stride; // distance between start points of each element
    debug const uint buffOffset;

    this(in ubyte[] buffer, uint length, uint offset, ubyte stride)
    {
        debug buffOffset = offset;
        buf = buffer[offset .. offset + length];
        this.stride = stride;
    }

    Accessor createAccessor(size_t idx, Json accessor)
    {
        enforce("sparse" !in accessor);
        const normalized = accessor["normalized"].opt!bool(false);
        enforce(!normalized);

        Json min_max;
        if("min" !in accessor)
            min_max = Json.emptyObject;
        else
        {
            min_max = Json([
                "min": accessor["min"],
                "max": accessor["max"],
            ]);
        }

        auto r = Accessor(
            viewIdx: idx,
            count: accessor["count"].get!uint,
            min_max: min_max,
            offset: accessor["byteOffset"].opt!uint,
            componentType: accessor["componentType"].get!ComponentType,
        );

        debug enforce(buffOffset % r.componentSizeOf == 0);
        enforce(r.offset % r.componentSizeOf == 0);

        debug
        {
            r.type = accessor["type"].get!string;
        }

        return r;
    }

    auto createGPUBuffer(LogicalDevice device, VkBufferUsageFlags flags) const
    {
        auto r = new BufferPieceOnGPU;
        r.buffer = device.create!TransferBuffer(buf.length, flags);

        r.buffer.cpuBuf[0 .. $] = cast(void[]) buf;

        return r;
    }
}

class BufferPieceOnGPU
{
    TransferBuffer buffer;

    //TODO: add flag if CPU buf is not needed after uploading
    void uploadImmediate(scope CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        buffer.uploadImmediate(commandPool, commandBuffer);
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
    const size_t viewIdx;
    uint offset;
    uint count;
    Json min_max;
    debug string type;
    ComponentType componentType;

    ubyte componentSizeOf() const
    {
        with(ComponentType)
        final switch(componentType)
        {
            case BYTE:          return 1;
            case UNSIGNED_BYTE: return 1;
            case SHORT:         return 2;
            case UNSIGNED_SHORT:return 2;
            case UNSIGNED_INT:  return 4;
            case FLOAT:         return 4;
        }
    }
}

struct Mesh
{
    string name;
    Primitive[] primitives;
}

struct Primitive
{
    int indicesAccessorIdx = -1;
    Json attributes;
    Json material;
}

struct NodePayload
{
    string name; /// Not a unique name
    Matrix4x4f trans;
    int meshIdx = -1;
}

struct Node
{
    ushort[] childrenNodeIndices;
    NodePayload payload;
    alias this = payload;
}

struct GltfContent
{
    //FIXME: remove, not needed t store it in GlTF object:
    View[] bufferViews;
    Accessor[] accessors;
    Mesh[] meshes;
    ImageMemory[] images;
    Texture[] textures;

    const BufAccess getAccess(in Accessor accessor)
    {
        const view = bufferViews[accessor.viewIdx];

        return BufAccess(
            offset: accessor.offset,
            stride: view.stride,
            viewIdx: accessor.viewIdx,
            count: accessor.count,
        );
    }

    auto rangify(T)(BufAccess bufAccessor) const
    {
        assert(bufAccessor.viewIdx >= 0);

        return AccessRange!T(bufferViews[bufAccessor.viewIdx], bufAccessor);
    }
}

//TODO: private?
struct BufAccess
{
    //TODO: remove?
    ptrdiff_t viewIdx = -1;
    uint offset;
    ubyte stride;
    uint count;
}

private struct AccessRange(T)
{
    private const View view;
    const BufAccess accessor;
    private const uint bufEnd;
    private uint currByte;
    private uint currStep;

    alias Elem = T;

    package this(in View v, in BufAccess a)
    {
        view = v;

        BufAccess tmp = a;
        if(tmp.stride == 0)
            tmp.stride = T.sizeof;

        accessor = tmp;
        currByte = a.offset;
        bufEnd = cast(uint) v.buf.length;

        enforce(accessor.stride >= T.sizeof);

        assert(!empty);
    }

    void popFront()
    {
        enforce(currByte <= bufEnd - T.sizeof);
        enforce(!empty);

        currStep++;
        currByte += accessor.stride;
    }

    uint length() const => accessor.count;
    bool empty() const => currStep >= length;

    version(LittleEndian)
    ref T front() const
    {
        return *(cast(T*) cast(void*) &view.buf[currByte]);
    }
    else
        static assert(false, "big endian not implemented");
}

private string build_path(string dir, string filename) => dir ~ std.path.dirSeparator ~ filename;

private Buffer readBufFile(string dir, in Json fileDescr)
{
    const len = fileDescr["byteLength"].get!ulong;
    const filename = fileDescr["uri"].get!string;

    Buffer ret;
    ret.buf = cast(ubyte[]) std.file.read(build_path(dir, filename));

    enforce(ret.buf.length == len);

    return ret;
}
