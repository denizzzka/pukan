module pukan.gltf.loader;

import pukan.gltf;
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
            enforce(primitive["mode"].opt!ushort(4) == 4, "only supported mode = 4 (TRIANGLES)");
            const indicesAccessorIdx = primitive["indices"].opt!int(-1);

            primitives ~= Primitive(
                indicesAccessorIdx: indicesAccessorIdx,
                attributes: primitive["attributes"],
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
            auto transJson = node["translation"].opt!(Json[]);
            if(transJson.length == 0)
                trans = Matrix4x4f.identity;
            else
            {
                auto a = transJson.array;
                enforce(a.length == 3);

                trans = Vector3f(a[0], a[1], a[2]).translationMatrix;

                //TODO: implement rotation and scale
            }
        }

        ret.nodes ~= Node(
            name: node["name"].opt!string,
            childrenNodeIndices: childrenIdxs,
            meshIdx: node["mesh"].opt!int(-1),
            trans: trans,
        );
    }

    auto scenes = json["scenes"].byValue.array;
    enforce(scenes.length == 1);

    {
        Json rootScene = scenes[ json["scene"].get!ushort ];

        ret.rootSceneNode.name = rootScene["name"].opt!string;
        ret.rootSceneNode.childrenNodeIndices = rootScene["nodes"]
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
            addressModeU: VK_SAMPLER_ADDRESS_MODE_REPEAT,
            addressModeV: VK_SAMPLER_ADDRESS_MODE_REPEAT,
            addressModeW: VK_SAMPLER_ADDRESS_MODE_REPEAT,
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

    return new GlTF(pipeline, descriptorSets, device, ret);
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
