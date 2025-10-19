module pukan.gltf;

import dlib.math;
public import pukan.gltf.loader: loadGlTF2;
public import pukan.gltf.factory: GltfFactory;
import pukan.vulkan.bindings;
import pukan.vulkan;
import std.exception: enforce;
import vibe.data.json;

struct Buffer
{
    ubyte[] buf;

    View createView(Json view)
    {
        const offset = view["byteOffset"].opt!size_t;

        return View(
            view: buf[ offset .. offset + view["byteLength"].get!size_t ],
            stride: view["byteStride"].opt!ubyte,
        );
    }
}

struct View
{
    ubyte[] view;
    const ubyte stride; // distance between start points of each element

    Accessor createAccessor(Json accessor)
    {
        enforce("sparse" !in accessor);

        const offset = accessor["byteOffset"].opt!size_t;
        const count = accessor["count"].get!uint;
        const len = stride ? (offset + stride*count) : view.length;

        auto r = Accessor(
            viewSlice: view[offset .. len],
            count: count,
        );

        debug
        {
            r.type = accessor["type"].get!string;
            r.componentType = accessor["componentType"].get!ComponentType;
            r.stride = stride;
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
    debug ubyte stride;
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
    Matrix4x4f trans;
    int meshIdx = -1;
    ushort[] childrenNodeIndices;
}

struct GltfContent
{
    Accessor[] accessors;
    Node[] nodes;
    Mesh[] meshes;
    Node rootSceneNode;
    ImageMemory[] images;
    Texture[] textures;
}

class GlTF : DrawableByVulkan
{
    private Texture fakeTexture;
    private GltfContent content;
    alias this = content;

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
            Vector4i renderType;
            Vector4f baseColorFactor;
        }

        Material material;
    }

    package this(ref GraphicsPipelineCfg pipeline, VkDescriptorSet[] ds, LogicalDevice device, GltfContent cont)
    {
        this.pipeline = &pipeline;
        descriptorSets = ds;
        content = cont;

        // TODO: bad idea to allocate a memory buffer only for one uniform buffer,
        // need to allocate more memory then divide it into pieces
        uniformBuffer = device.create!TransferBuffer(UBOContent.sizeof, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);

        ubo.material.baseColorFactor = Vector4f(0, 1, 1, 1);
        ubo.material.renderType.x = textures.length ? 1 : 0;

        fakeTexture = createFakeTexture1x1(device);
        updateDescriptorSetsAndUniformBuffers(device);
    }

    ~this()
    {
        uniformBuffer.destroy;
    }

    private ref UBOContent ubo()
    {
        return *cast(UBOContent*) uniformBuffer.cpuBuf.ptr;
    }

    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        assert(rootSceneNode.childrenNodeIndices.length > 0);

        foreach(rootNodeIdx; rootSceneNode.childrenNodeIndices)
            uploadNodeToGPU(device, commandPool, commandBuffer, nodes[rootNodeIdx]);
    }

    private void uploadNodeToGPU(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer, in Node node)
    {
        //TODO: just skip such node
        enforce(node.meshIdx >= 0, "mesh index not found");

        const mesh = &meshes[node.meshIdx];
        assert(mesh.primitives.length == 1);

        const primitive = &mesh.primitives[0];
        enforce(primitive.indicesAccessorIdx != -1, "non-indexed geometry isn't supported");

        {
            auto indices = accessors[ primitive.indicesAccessorIdx ];
            enforce(indices.stride == 0);

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

            enforce(vertices.count > 0);
            debug assert(vertices.type == "VEC3");
            debug assert(vertices.componentType == ComponentType.FLOAT);

            import dlib.math: Vector3f;
            static assert(Vector3f.sizeof == float.sizeof * 3);

            size_t sz = vertices.count;
            if(vertices.stride == 0)
                sz *= Vector3f.sizeof;
            else
            {
                enforce(vertices.stride == Vector3f.sizeof);
                sz *= vertices.stride;
            }

            vertexBuffer = device.create!TransferBuffer(sz, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

            // Copy vertices to mapped memory
            vertexBuffer.cpuBuf[0..$] = cast(void[]) vertices.viewSlice;

            vertexBuffer.uploadImmediate(commandPool, commandBuffer);
        }
    }

    private void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
    {
        VkDescriptorBufferInfo bufferInfo = {
            buffer: uniformBuffer.gpuBuffer,
            offset: 0,
            range: UBOContent.sizeof,
        };

        assert(descriptorSets.length == 1);

        {
            import std.conv: to;
            assert(textures.length <= 1, textures.length.to!string);
        }

        VkDescriptorImageInfo imageInfo;

        if(textures.length == 0)
        {
            imageInfo = VkDescriptorImageInfo(
                imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                imageView: fakeTexture.imageView,
                sampler: fakeTexture.sampler,
            );
        }
        else
        {
            imageInfo = VkDescriptorImageInfo(
                imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                imageView: textures[0].imageView,
                sampler: textures[0].sampler,
            );
        }

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
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: descriptorSets[0],
                dstBinding: 1,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                pImageInfo: &imageInfo,
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

        VkDeviceSize[] offsets = [VkDeviceSize(0)];

        vkCmdPushConstants(buf, pipeline.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, cast(uint) trans.sizeof, cast(void*) &trans);

        //TODO: pass few buffers simultaneously
        vkCmdBindVertexBuffers(buf, 0, 1, &(vertexBuffer.gpuBuffer.buf.getVal()), offsets.ptr);
        vkCmdBindIndexBuffer(buf, indicesBuffer.gpuBuffer.buf, 0, VK_INDEX_TYPE_UINT16);
        vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipelineLayout, 0, cast(uint) descriptorSets.length, descriptorSets.ptr, 0, null);

        vkCmdDrawIndexed(buf, indices_count, 1, 0, 0, 0);
    }
}

//TODO: use as mandatory vertex shader creation argument?
struct ShaderInputVertex
{
    Vector3f pos;
    Vector2f texCoord;

    //TODO: convert to enum?
    static auto getBindingDescriptions()
    {
        return [
            VkVertexInputBindingDescription(
                binding: 0,
                stride: pos.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
        ];
    }

    //TODO: convert to enum?
    static auto getAttributeDescriptions()
    {
        VkVertexInputAttributeDescription[2] ad = [
            // position:
            VkVertexInputAttributeDescription(
                binding: 0,
                location: 0,
                format: VK_FORMAT_R32G32B32_SFLOAT,
                //~ offset: pos.offsetof,
            ),
            // textureCoord:
            VkVertexInputAttributeDescription(
                binding: 0,
                location: 1,
                format: VK_FORMAT_R32G32_SFLOAT,
                //~ offset: texCoord.offsetof,
            ),
        ];

        return ad;
    }
};
