module pukan.mesh;

import dlib.math: Matrix4x4f, Vector4f, Vector4i;
import pukan.vulkan;
import pukan.vulkan.bindings;

/// One vertex buffer bound to a vertex input binding
struct VertexStream
{
    VkBuffer buffer;
    VkDeviceSize offset;
    VkDeviceSize size;
    uint stride;
}

struct Material
{
    Vector4i renderType;
    Vector4f baseColorFactor;
}

struct UBOContent
{
    Material material;
}

/// Material uniforms of all meshes, one slot per mesh
final class MaterialBuffer
{
    private LogicalDevice device;
    private TransferBuffer buffer;
    private size_t capacity;
    private size_t used;
    private VkDescriptorSet[] descriptorSets;
    private size_t slotSize;

    this(LogicalDevice device, size_t initialCapacity = 16)
    in(initialCapacity > 0)
    {
        this.device = device;
        this.capacity = initialCapacity;

        const alignment = cast(size_t) device.physicalDevice.properties.limits.minUniformBufferOffsetAlignment;
        slotSize = alignment > 1
            ? (UBOContent.sizeof + alignment - 1) / alignment * alignment
            : UBOContent.sizeof;

        buffer = device.create!TransferBuffer(capacity * slotSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
    }

    ~this()
    {
        if(buffer)
            destroy(buffer);
    }

    /// Reserves a slot for the given descriptor set
    size_t addSlot(VkDescriptorSet set)
    {
        if(used == capacity)
            grow();

        const slot = used++;
        descriptorSets ~= set;

        return slot;
    }

    ref UBOContent content(size_t slot)
    {
        assert(slot < used);

        return *cast(UBOContent*) (cast(ubyte*) buffer.cpuBuf.ptr + slot * slotSize);
    }

    VkDescriptorBufferInfo info(size_t slot)
    {
        assert(slot < used);

        return VkDescriptorBufferInfo(
            buffer: buffer.gpuBuffer,
            offset: slot * slotSize,
            range: UBOContent.sizeof,
        );
    }

    void uploadImmediate(CommandPool commandPool, VkCommandBuffer commandBuffer)
    {
        buffer.uploadImmediate(commandPool, commandBuffer);
    }

    private void grow()
    {
        const newCapacity = capacity * 2;

        auto newBuffer = device.create!TransferBuffer(
            newCapacity * slotSize,
            VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        );

        const usedBytes = used * slotSize;
        newBuffer.cpuBuf[0 .. usedBytes] = buffer.cpuBuf[0 .. usedBytes];

        buffer.destroy;
        buffer = newBuffer;
        capacity = newCapacity;

        foreach(i, set; descriptorSets)
        {
            auto bufferInfo = info(i);

            VkWriteDescriptorSet[] writes = [
                bufferWriteDescriptor(set, 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, bufferInfo),
            ];

            device.updateDescriptorSets(writes);
        }
    }
}

/// Resources shared by static and skinned meshes
final class MeshResources
{
    MaterialBuffer materials;
    MemoryBufferMappedToCPU identityJoints;
    VkDescriptorBufferInfo identityJointsInfo;
    Texture fakeTexture;

    this(LogicalDevice device, size_t materialCapacity = 16)
    {
        materials = new MaterialBuffer(device, materialCapacity);

        identityJoints = device.create!MemoryBufferMappedToCPU(
            Matrix4x4f.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );
        (cast(Matrix4x4f[]) identityJoints.cpuBuf)[0] = Matrix4x4f.identity;
        identityJointsInfo = VkDescriptorBufferInfo(
            buffer: identityJoints.buf,
            offset: 0,
            range: Matrix4x4f.sizeof,
        );

        fakeTexture = createFakeTexture1x1(device);
    }

    ~this()
    {
        if(fakeTexture)
            destroy(fakeTexture);

        if(identityJoints)
            destroy(identityJoints);

        if(materials)
            destroy(materials);
    }
}

/// Geometry and descriptor set shared by static and skinned meshes
class Mesh
{
    string name;
    VkDescriptorSet descriptorSet;
    uint vertexCount;

    VkBuffer indexBuffer;
    VkDeviceSize indexOffset;
    VkIndexType indexType;
    uint indexCount;

    private VkBuffer[] buffers;
    private VkDeviceSize[] offsets;
    private VkDeviceSize[] sizes;
    private VkDeviceSize[] strides;

    /// Sets the vertex streams in vertex input binding order
    void setStreams(VertexStream[] streams)
    {
        buffers.length = streams.length;
        offsets.length = streams.length;
        sizes.length = streams.length;
        strides.length = streams.length;

        foreach(i, ref stream; streams)
        {
            buffers[i] = stream.buffer;
            offsets[i] = stream.offset;
            sizes[i] = stream.size;
            strides[i] = stream.stride;
        }
    }

    void draw(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f trans)
    {
        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);
        drawGeometry(buf, pipeline, trans);
    }

    /// Draws assuming the pipeline is already bound
    void drawGeometry(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f trans)
    {
        vkCmdPushConstants(
            buf,
            pipeline.pipelineLayout,
            VK_SHADER_STAGE_VERTEX_BIT,
            0,
            cast(uint) trans.sizeof,
            cast(void*) &trans,
        );

        if(buffers.length)
            vkCmdBindVertexBuffers2(
                buf,
                0,
                cast(uint) buffers.length,
                buffers.ptr,
                offsets.ptr,
                sizes.ptr,
                strides.ptr,
            );

        if(indexCount)
            vkCmdBindIndexBuffer(buf, indexBuffer, indexOffset, indexType);

        if(descriptorSet)
            vkCmdBindDescriptorSets(
                buf,
                VK_PIPELINE_BIND_POINT_GRAPHICS,
                pipeline.pipelineLayout,
                0,
                1,
                &descriptorSet,
                0,
                null,
            );

        if(indexCount)
            vkCmdDrawIndexed(buf, indexCount, 1, 0, 0, 0);
        else
            vkCmdDraw(buf, vertexCount, 1, 0, 0);
    }
}
