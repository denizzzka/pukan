module pukan.gltf.loader;

import dlib.math;
import pukan.gltf: GlTF;
import pukan.gltf.accessor;
import pukan.gltf.animation;
import pukan.vulkan.bindings;
import pukan.vulkan;
import std.algorithm;
import std.array;
import std.conv: to;
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
package auto loadGlTF2(string filename, PoolAndLayoutInfo poolAndLayout, LogicalDevice device, ref GraphicsPipelineCfg pipeline, Texture fakeTexture)
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
    auto content = &ret; //TODO: replace by ref
    Node[] nodes;
    Node rootSceneNode;

    if(gltfFile.buffer)
        buffers ~= Buffer(buf: gltfFile.buffer);
    else
        foreach(buf; json["buffers"])
            buffers ~= readBufUri(dir, buf);

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

    const skins = "skins" in json;
    if(skins) foreach(ref skin; *skins)
    {
        uint[] joints;
        foreach(j; skin["joints"])
            joints ~= j.get!uint;

            auto invAcc = content.getAccess!(Type.MAT4)(
                skin["inverseBindMatrices"].get!uint
            );

        ret.skins ~= Skin(
            inverseBindMatrices: content.rangify!Matrix4x4f(invAcc),
            nodesIndices: joints,
        );
    }

    foreach(node; json["nodes"])
    {
        ushort[] childrenIdxs;
        const children = "children" in node;
        if(children)
            foreach(child; *children)
                childrenIdxs ~= child.get!ushort;

        nodes ~= Node(
            childrenNodeIndices: childrenIdxs,
            trans: readNodeTrans(node),
            payload: NodePayload(
                name: node["name"].opt!string,
                meshIdx: node["mesh"].opt!int(-1),
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
                "Unsupported image type: "~(*mime).to!string
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

    // Load animations
    {
        auto animations = "animations" in json;
        if(animations) foreach(animation; *animations)
        {
            Animation r;
            r.name = animation["name"].opt!string;

            foreach(sampler; animation["samplers"])
            {
                r.samplers ~= AnimationSampler(
                    inputAcc: content.getAccess!(Type.SCALAR)(sampler["input"].get!uint),
                    outputAcc: content.getAccess(sampler["output"].get!uint),
                    interpolation: sampler["interpolation"].opt!string(InterpolationType.LINEAR).to!InterpolationType,
                );
            }

            foreach(channel; animation["channels"])
            {
                const target = channel["target"];

                r.channels ~= Channel(
                    samplerIdx: channel["sampler"].get!uint,
                    targetPath: target["path"].get!string.to!TRSType,
                    targetNode: target["node"].get!uint,
                );
            }

            ret.animations ~= r;
        }
    }

    return new GlTF(pipeline, poolAndLayout, device, ret, nodes, rootSceneNode, fakeTexture);
}

private Matrix4x4f readNodeTrans(in Json node)
{
    import dlib.math;

    {
        auto json = "matrix" in node;
        if(json !is null)
        {
            auto a = (*json).deserializeJson!(float[16]);
            return Matrix4x4f(a);
        }
    }

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

    return tr.translationMatrix * rot.toMatrix4x4 * scale.scaleMatrix;
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
            type: accessor["type"].get!string.to!Type,
            componentType: accessor["componentType"].get!ComponentType,
        );

        enforce(buffOffset % r.componentSizeOf == 0);
        enforce(r.offset % r.componentSizeOf == 0);

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

enum ComponentType : short
{
    BYTE = 5120,
    UNSIGNED_BYTE = 5121,
    SHORT = 5122,
    UNSIGNED_SHORT = 5123,
    UNSIGNED_INT = 5125,
    FLOAT = 5126,
}

enum Type : string
{
    undef = null,
    SCALAR = "SCALAR",
    VEC2 = "VEC2",
    VEC3 = "VEC3",
    VEC4 = "VEC4",
    MAT2 = "MAT2",
    MAT3 = "MAT3",
    MAT4 = "MAT4",
}

struct Accessor
{
    const size_t viewIdx;
    uint offset;
    uint count;
    Json min_max;
    Type type;
    ComponentType componentType;

    ubyte componentSizeOf() const => .componentSizeOf(componentType);
    ubyte typeSizeOf() const
    {
        ubyte compNum;

        with(Type)
        final switch(type)
        {
            case SCALAR: compNum = 1; break;
            case VEC2: compNum = 2; break;
            case VEC3: compNum = 3; break;
            case VEC4:
            case MAT2: compNum = 4; break;
            case MAT3: compNum = 9; break;
            case MAT4: compNum = 16; break;

            case undef: assert(0);
        }

        return cast(ubyte) (componentSizeOf * compNum);
    }
}

ubyte componentSizeOf(in ComponentType componentType)
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

//TODO: (dlib) make Matrix4x4f.inverse() const:

struct Skin
{
    package uint[] nodesIndices; /// skin joints
    //TODO: const
    private AccessRange!(Matrix4x4f, false) inverseBindMatrices;

    Matrix4x4f[] calculateJointMatrices(in GltfContent* content, /* in */ Matrix4x4f[] baseNodeTranslations, ref /*TODO: in*/ Matrix4x4f[] perNodeTranslations, ref /*TODO: in*/ Matrix4x4f[] rootRelativeNodeTranslations, in ushort skinNodeIdx) const
    {
        Matrix4x4f[] jointMatrices;
        jointMatrices.length = nodesIndices.length;

        assert(inverseBindMatrices.length == jointMatrices.length);

        //~ auto G_inv = perNodeTranslations[skinNodeIdx].inverse;

        foreach(i, jointIdx; nodesIndices)
        {
            // Fourth row is fixed and described in the spec:
            //assert(inverseBindMatrices[i].getRow(3) == Vector4f([0.0, 0.0, 0.0, 1.0]));

            //~ jointMatrices[i] = inverseBindMatrices[i].inverse * baseNodeTranslations[jointIdx] * inverseBindMatrices[i];
            //~ jointMatrices[i] = inverseBindMatrices[i] * perNodeTranslations[jointIdx];
            //~ jointMatrices[i] = inverseBindMatrices[i].inverse * perNodeTranslations[jointIdx];
            //~ auto relativeToSkinSpace = baseNodeTranslations[jointIdx] * inverseBindMatrices[i];
            //~ auto relativeToSkinSpace = inverseBindMatrices[i].inverse * baseNodeTranslations[jointIdx];
            //~ jointMatrices[i] = baseNodeTranslations[jointIdx] * inverseBindMatrices[i] * rootRelativeNodeTranslations[jointIdx];
            //~ jointMatrices[i] = Matrix4x4f.identity;

            // Move rest pose vertex into skin space
            //~ auto pos = baseNodeTranslations[jointIdx] * inverseBindMatrices[i];

            // Move vertex back into model space, but with skin related to current position
            //~ jointMatrices[i] = pos;

            //~ baseNodeTranslations[jointIdx] * inverseBindMatrices[i] inverseTransform * perNodeTranslations[jointIdx] * inverseBindMatrices[i];

            //TODO: can be calculated once during load:
            //~ auto skinRootRelative = baseNodeTranslations[jointIdx] * inverseBindMatrices[i];
            //~ jointMatrices[i] = baseNodeTranslations[jointIdx] * inverseBindMatrices[i];
            //~ auto skinRootRelative = baseNodeTranslations[jointIdx] * inverseBindMatrices[i].inverse;
            //~ auto tmp = rootRelativeNodeTranslations[jointIdx] * inverseBindMatrices[i];
            //~ jointMatrices[i] = perNodeTranslations[jointIdx] * inverseBindMatrices[i];
            jointMatrices[i] = rootRelativeNodeTranslations[jointIdx] * inverseBindMatrices[i];
            //~ jointMatrices[i] = skinRootRelative * perNodeTranslations[jointIdx];


            //~ auto rotation = rotationQuaternion(Vector3f(0, 1, 0), 10f.degtorad);
            //~ jointMatrices[i] = rotation.toMatrix4x4 * jointMatrices[i];

            //~ import std;
            //~ writeln("perNodeTranslations");
            //~ writeln(perNodeTranslations);
            //~ writeln("rootRelativeNodeTranslations");
            //~ writeln(rootRelativeNodeTranslations);
        }

        return jointMatrices;
    }
}

struct NodePayload
{
    string name; /// Not a unique name
    int meshIdx = -1;
}

struct Node
{
    ushort[] childrenNodeIndices;
    Matrix4x4f trans;
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
    Animation[] animations;
    Skin[] skins;

    const BufAccess getAccess(Type type = Type.undef, T = void)(in uint accessorIdx)
    {
        auto acc = accessors[accessorIdx];

        return getAccess!(type, T)(acc);
    }

    const BufAccess getAccess(Type type = Type.undef, T = void)(in Accessor accessor)
    {
        static if(type != Type.undef)
            debug assert(accessor.type == type, accessor.type~" != "~type);

        const view = bufferViews[accessor.viewIdx];

        static if(!is(T == void))
        {
            const stride = view.stride ? view.stride : accessor.typeSizeOf;
            assert(stride >= T.sizeof);
        }
        else
        {
            // tightly packed data of unknown type
            const stride = 0;
        }

        return BufAccess(
            offset: accessor.offset,
            stride: stride,
            viewIdx: accessor.viewIdx,
            count: accessor.count,
        );
    }

    auto rangify(T, bool isOutput = false)(BufAccess bufAccessor) const
    {
        assert(bufAccessor.viewIdx >= 0);

        return AccessRange!(T, isOutput)(bufferViews[bufAccessor.viewIdx].buf, bufAccessor);
    }
}

private string build_path(string dir, string filename) => dir ~ std.path.dirSeparator ~ filename;

private Buffer readBufUri(string dir, in Json fileDescr)
{
    import std.algorithm.searching: startsWith;
    import std.base64;

    const len = fileDescr["byteLength"].get!ulong;
    const uri = fileDescr["uri"].get!string;

    immutable magic = "data:application/gltf-buffer;base64,";
    Buffer ret;

    if(!uri.startsWith(magic))
        ret.buf = cast(ubyte[]) std.file.read(build_path(dir, uri));
    else
    {
        const based = uri[magic.length .. $];
        ret.buf = Base64.decode(based);
    }

    enforce(ret.buf.length == len);

    return ret;
}
