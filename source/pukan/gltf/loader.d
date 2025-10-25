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

///
auto loadGlTF2(string filename, VkDescriptorSet[] descriptorSets, LogicalDevice device, ref GraphicsPipelineCfg pipeline)
{
    const json = std.file.readText(filename).parseJsonString;
    const dir = std.path.dirName(filename);

    {
        const ver = json["asset"]["version"].get!string;
        enforce(ver == "2.0", "glTF version "~ver~" unsupported");
    }

    GltfContent ret;
    Node[] nodes;
    Node rootSceneNode;

    foreach(buf; json["buffers"])
        ret.buffers ~= readBufFile(dir, buf);

    foreach(v; json["bufferViews"])
    {
        const idx = v["buffer"].get!uint;
        ret.bufferViews ~= ret.buffers[idx].createView(idx, v);
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
        Json rootScene = scenes[ json["scene"].get!ushort ];

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
    if(images) foreach(img; *images)
    {
        import pukan.misc: loadImageFromFile;

        auto extFormatImg = loadImageFromFile(build_path(dir, img["uri"].get!string));
        ret.images ~= loadImageToMemory(device, commandPool, commandBufs[0], extFormatImg);
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

    return new GlTF(pipeline, descriptorSets, device, ret, nodes, rootSceneNode);
}

struct Buffer
{
    ubyte[] buf;

    View createView(size_t idx, Json view)
    {
        return View(
            bufferIdx: idx,
            offset: view["byteOffset"].opt!uint,
            stride: view["byteStride"].opt!ubyte,
        );
    }
}

struct View
{
    const size_t bufferIdx;
    const uint offset;
    const ubyte stride; // distance between start points of each element

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
        );

        debug
        {
            r.type = accessor["type"].get!string;
            r.componentType = accessor["componentType"].get!ComponentType;
        }

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

struct Accessor
{
    const size_t viewIdx;
    uint offset;
    uint count;
    Json min_max;
    debug string type;
    debug ComponentType componentType;
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
    Buffer[] buffers;
    View[] bufferViews;
    Accessor[] accessors;
    Mesh[] meshes;
    ImageMemory[] images;
    Texture[] textures;

    const BufAccess getAccess(in Accessor accessor)
    {
        const view = bufferViews[accessor.viewIdx];

        return BufAccess(
            offset: view.offset + accessor.offset,
            stride: view.stride,
            bufIdx: view.bufferIdx,
        );
    }
}

struct BufAccess
{
    ptrdiff_t bufIdx = -1;
    uint offset;
    ushort stride;
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
