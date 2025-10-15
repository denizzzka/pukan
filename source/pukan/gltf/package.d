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
auto loadGlTF2(string filename, VkDescriptorSet[] descriptorSets, LogicalDevice device, ref GraphicsPipelineCfg pipeline)
{
    const json = std.file.readText(filename).parseJsonString;
    const dir = std.path.dirName(filename);

    {
        const ver = json["asset"]["version"].get!string;
        enforce(ver == "2.0", "glTF version "~ver~" unsupported");
    }

    auto ret = new GlTF(pipeline, descriptorSets, device);

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

        ret.nodes ~= Node(
            name: node["name"].opt!string,
            childrenNodeIndices: childrenIdxs,
            meshIdx: node["mesh"].opt!int(-1),
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

    ret.updateDescriptorSetsAndUniformBuffers(device);

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

        auto r = Accessor(
            viewSlice: bufSlice[offset .. $],
            count: accessor["count"].get!uint,
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
    ubyte[] viewSlice;
    uint count;
    debug string type;
    debug ComponentType componentType;
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
    int indicesAccessorIdx = -1;
    Json attributes;
}

struct Node
{
    string name; /// Not a unique name
    int meshIdx = -1;
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
    private TransferBuffer vertexBuffer;
    private GraphicsPipelineCfg* pipeline;
    private VkDescriptorSet[] descriptorSets;
    private TransferBuffer uniformBuffer;
    private ushort indices_count;

    static struct UBOContent
    {
        static struct Material
        {
            Vector4f baseColorFactor;
        }

        Material material;
    }

    private this(ref GraphicsPipelineCfg pipeline, VkDescriptorSet[] ds, LogicalDevice device)
    {
        this.pipeline = &pipeline;
        descriptorSets = ds;

        // TODO: bad idea to allocate a memory buffer only for one uniform buffer,
        // need to allocate more memory then divide it into pieces
        uniformBuffer = device.create!TransferBuffer(UBOContent.sizeof, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);

        auto ubo = cast(UBOContent*) uniformBuffer.cpuBuf.ptr;
        ubo.material.baseColorFactor = Vector4f(0, 1, 0.2, 1);
    }

    ~this()
    {
        uniformBuffer.destroy;
    }

    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        assert(rootSceneNode.childrenNodeIndices.length == 1);
        const node = nodes[ rootSceneNode.childrenNodeIndices[0] ];

        //TODO: just skip such node
        enforce(node.meshIdx >= 0, "mesh index not found");

        const mesh = &meshes[node.meshIdx];
        assert(mesh.primitives.length == 1);

        const primitive = &mesh.primitives[0];
        enforce(primitive.indicesAccessorIdx != -1, "non-indexed geometry isn't supported");

        {
            auto indices = accessors[ primitive.indicesAccessorIdx ];

            debug
            {
                import std.conv: to;

                enforce(indices.type == "SCALAR", indices.type.to!string);
                enforce(indices.componentType == ComponentType.UNSIGNED_SHORT, indices.componentType.to!string);
            }

            assert(indices.count > 0);
            indices_count = cast(ushort) indices.count;

            indicesBuffer = device.create!TransferBuffer(ushort.sizeof * indices.count, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);

            assert(indicesBuffer.cpuBuf.length == indices.viewSlice.length);

            // Copy indices to mapped memory
            indicesBuffer.cpuBuf[0..$] = cast(void[]) indices.viewSlice;

            indicesBuffer.uploadImmediate(commandPool, commandBuffer);
        }

        {
            const vertIdx = primitive.attributes["POSITION"].get!ushort;
            auto vertices = &accessors[vertIdx];

            assert(vertices.count > 0);
            debug assert(vertices.type == "VEC3");
            debug assert(vertices.componentType == ComponentType.FLOAT);

            import dlib.math: Vector3f;
            static assert(Vector3f.sizeof == float.sizeof * 3);

            vertexBuffer = device.create!TransferBuffer(Vector3f.sizeof * vertices.count, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

            // Copy vertices to mapped memory
            vertexBuffer.cpuBuf[0..$] = cast(void[]) vertices.viewSlice;

            vertexBuffer.uploadImmediate(commandPool, commandBuffer);
        }
    }

    void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
    {
        VkDescriptorBufferInfo bufferInfo = {
            buffer: uniformBuffer.gpuBuffer,
            offset: 0,
            range: UBOContent.sizeof,
        };

        assert(descriptorSets.length == 1);

        VkWriteDescriptorSet[] descriptorWrites = [
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: descriptorSets[0],
                dstBinding: 0,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                pBufferInfo: &bufferInfo,
            ),
        ];

        device.updateDescriptorSets(descriptorWrites);
    }

    void refreshBuffers(VkCommandBuffer buf)
    {
        uniformBuffer.recordUpload(buf);
    }

    void drawingBufferFilling(VkCommandBuffer buf, GraphicsPipelineCfg pipeline_UNUSED_FIXME_REMOVE, Matrix4x4f trans)
    {
        //~ trans *= Vector3f(-1, -1, -1).scaleMatrix;

        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);

        auto vertexBuffers = [vertexBuffer.gpuBuffer.buf];
        VkDeviceSize[] offsets = [VkDeviceSize(0)];

        vkCmdPushConstants(buf, pipeline.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, cast(uint) trans.sizeof, cast(void*) &trans);

        vkCmdBindVertexBuffers(buf, 0, 1, vertexBuffers.ptr, offsets.ptr);
        vkCmdBindIndexBuffer(buf, indicesBuffer.gpuBuffer.buf, 0, VK_INDEX_TYPE_UINT16);
        vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipelineLayout, 0, cast(uint) descriptorSets.length, descriptorSets.ptr, 0, null);

        vkCmdDrawIndexed(buf, indices_count, 1, 0, 0, 0);
    }
}

struct GltfFactory
{
    import pukan.vulkan;
    import shaders = pukan.vulkan.shaders;
    import pukan.vulkan.frame_builder;

    LogicalDevice device;
    private PoolAndLayoutInfo poolAndLayout;
    //TODO: contains part of poolAndLayout data. Deduplicate?
    private DefaultGraphicsPipelineInfoCreator!Vertex3 pipelineInfoCreator;
    GraphicsPipelineCfg graphicsPipelineCfg;

    this(LogicalDevice device, ShaderInfo[] shaderStages, RenderPass renderPass)
    {
        this.device = device;

        auto layoutBindings = shaders.createLayoutBinding(shaderStages);
        poolAndLayout = device.createDescriptorPool(layoutBindings);

        pipelineInfoCreator = new DefaultGraphicsPipelineInfoCreator!Vertex3(device, [poolAndLayout.descriptorSetLayout], shaderStages, renderPass);
        graphicsPipelineCfg.pipelineLayout = pipelineInfoCreator.pipelineLayout;

        auto pipelineCreateInfo = pipelineInfoCreator.pipelineCreateInfo;
        graphicsPipelineCfg.graphicsPipeline = device.createGraphicsPipelines([pipelineCreateInfo])[0];
    }

    auto create(string filename)
    {
        assert(device);
        auto descriptorSets = device.allocateDescriptorSets(poolAndLayout, 1);

        return loadGlTF2(filename, descriptorSets, device, graphicsPipelineCfg);
    }
}

struct Vertex3
{
    Vector3f pos;

    static auto getBindingDescription()
    {
        VkVertexInputBindingDescription r = {
            binding: 0,
            stride: this.sizeof,
            inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
        };

        return r;
    }

    static auto getAttributeDescriptions()
    {
        VkVertexInputAttributeDescription[1] ad;

        ad[0] = VkVertexInputAttributeDescription(
            binding: 0,
            location: 0,
            format: VK_FORMAT_R32G32B32_SFLOAT,
            offset: pos.offsetof,
        );

        return ad;
    }
};
