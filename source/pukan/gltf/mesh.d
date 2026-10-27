module pukan.gltf.mesh;

import dlib.math;
import pukan.gltf.accessor;
public import pukan.gltf.loader: ComponentType;
import pukan.misc: Boxf, expandAABB;
import pukan.vulkan;
import pukan.vulkan.bindings;
import std.conv: to;

static struct Material
{
    Vector4i renderType;
    Vector4f baseColorFactor;
}

struct UBOContent
{
    Material material;
}

struct IndicesDescr
{
    BufAccess accessor;
    VkIndexType indexType;

    this(LogicalDevice device, BufAccess acc, ComponentType t)
    {
        assert(acc.stride == 0 || acc.stride == 2 || acc.stride == 4);

        accessor = acc;

        with(ComponentType)
        switch(t)
        {
            case UNSIGNED_SHORT: indexType = VK_INDEX_TYPE_UINT16; break;
            case UNSIGNED_INT: indexType = VK_INDEX_TYPE_UINT32; break;
            default: assert(0);
        }
    }
}

/// Vertices, uploaded to GPU
package struct UploadedVertices
{
    IndicesDescr indices;
    union
    {
        BufAccess[4] allBuffers;
        struct
        {
            BufAccess vertices;
            BufAccess texCoords;

            // Skin support
            BufAccess joints;
            BufAccess weights;
        }
    }
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

class Mesh
{
    string name;
    package UploadedVertices vert;
    alias this = vert;
    /*private*/ VkDescriptorSet descriptorSet;

    private MaterialBuffer materialBuffer;
    private size_t materialSlot;

    private VkWriteDescriptorSet jointsUboWriteDescr;

    package this(
        string name,
        UploadedVertices vert,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        ref VkDescriptorBufferInfo jointsUboInfo,
    )
    {
        this.name = name;
        this.materialBuffer = materialBuffer;
        this.descriptorSet = allocator.allocate();
        this.vert = vert;

        materialSlot = materialBuffer.addSlot(descriptorSet);

        assert(vertices.viewIdx >= 0);

        if(vert.texCoords.viewIdx < 0)
            this.vert.texCoords = vert.vertices; // fake data to fill out texture coords buffer on non-textured objects

        ubo.material.baseColorFactor = Vector4f(0, 1, 1, 1);
        ubo.material.renderType.x = 0; // is not textured

        jointsUboWriteDescr = bufferWriteDescriptor(descriptorSet, 2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, jointsUboInfo);
    }

    package auto calcAABB(in BufferPieceOnGPU[] gpuBuffs, ref Boxf box) const
    {
        import std.math: isNaN;

        auto range = AccessRange!(Vector3f, false)(gpuBuffs[vertices.viewIdx].buffer.cpuBuf, vertices);

        if(box.min.x.isNaN)
        {
            box.min = range.front;
            box.max = box.min;

            range.popFront;
        }

        foreach(e; range)
            expandAABB(box, e);
    }

    private ref UBOContent ubo()
    {
        return materialBuffer.content(materialSlot);
    }

    abstract void updateDescriptorSetsAndUniformBuffers(LogicalDevice device);

    //TODO: remove?
    package void refreshBuffers(VkCommandBuffer buf)
    {
    }

    void drawingBufferFilling(BufferPieceOnGPU[] gpuBuffs, GraphicsPipelineCfg* pipeline, VkCommandBuffer buf)
    {
        vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipelineLayout, 0, 1, &descriptorSet, 0, null);

        bindVertexBuffers(gpuBuffs, vert.allBuffers, buf, vertices.count);

        if(indices.accessor.count == 0)
        {
            // Non-indexed mesh
            vkCmdDraw(buf, vertices.count, 1, 0, 0);
        }
        else
        {
            auto indicesBuffer = gpuBuffs[indices.accessor.viewIdx];
            assert(indicesBuffer !is null);

            vkCmdBindIndexBuffer(buf, indicesBuffer.buffer.gpuBuffer.buf.getVal(), indices.accessor.offset, indices.indexType);
            vkCmdDrawIndexed(buf, indices.accessor.count, 1, 0, 0, 0);
        }
    }
}

private void bindVertexBuffers(BufferPieceOnGPU[] gpuBuffs, /*in*/ BufAccess[] accessors, VkCommandBuffer cmdBuf, /*TODO: remove */ uint verticesNum)
in(gpuBuffs.length > 0)
{
    const len = cast(uint) accessors.length;
    assert(len > 0);

    auto buffers = new VkBuffer[len];
    auto offsets = new VkDeviceSize[len];
    auto sizes = new VkDeviceSize[len];
    auto strides = new VkDeviceSize[len];

    foreach(i, /*const*/ acc; accessors)
    {
        //FIXME: remove! just for testing meshes without skin
        if(acc.viewIdx < 0) // means no skin on this mesh
        {
            if(i == 2) // FIXME: hardcoded joints place
            {
                acc.viewIdx = gpuBuffs.length - 2; // fake joints buffer
                acc.count = verticesNum;
            }
            else if(i == 3) // hardcoded weights place
            {
                acc.viewIdx = gpuBuffs.length - 1;
                acc.count = verticesNum;
            }
        }

        assert(acc.viewIdx >= 0);

        auto gpuBuf = gpuBuffs[acc.viewIdx];
        assert(gpuBuf !is null);

        buffers[i] = gpuBuf.buffer.gpuBuffer.buf.getVal();
        offsets[i] = acc.offset;
        sizes[i] = gpuBuf.buffer.cpuBuf.length - acc.offset; // means buffer isn't more than this size
        strides[i] = acc.stride;
    }

    vkCmdBindVertexBuffers2(cmdBuf, 0, len, &buffers[0], &offsets[0], &sizes[0], &strides[0]);
}

///
final class JustColoredMesh : Mesh
{
    private VkDescriptorImageInfo fakeTexture;

    package this(
        string name,
        UploadedVertices vert,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        VkDescriptorImageInfo fakeTexture,
        ref VkDescriptorBufferInfo jointsUboInfo,
    )
    {
        this.fakeTexture = fakeTexture;

        super(name, vert, allocator, materialBuffer, jointsUboInfo);
    }

    override void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
    {
        auto uboInfo = materialBuffer.info(materialSlot);

        VkWriteDescriptorSet[] descriptorWrites = [
            jointsUboWriteDescr,
            bufferWriteDescriptor(descriptorSet, 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, uboInfo),
            imageWriteDescriptor(descriptorSet, 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, fakeTexture),
        ];

        device.updateDescriptorSets(descriptorWrites);
    }
}

///
final class TexturedMesh : Mesh
{
    /*private*/ VkDescriptorImageInfo* textureDescrImageInfo;

    package this(
        string name,
        UploadedVertices vert,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        ref VkDescriptorBufferInfo jointsUboInfo,
    )
    {
        super(name, vert, allocator, materialBuffer, jointsUboInfo);

        ubo.material.renderType.x = 1; // is textured
    }

    override void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
    {
        auto uboInfo = materialBuffer.info(materialSlot);

        VkWriteDescriptorSet[] descriptorWrites = [
            jointsUboWriteDescr,
            bufferWriteDescriptor(descriptorSet, 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, uboInfo),
            imageWriteDescriptor(descriptorSet, 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, *textureDescrImageInfo),
        ];

        device.updateDescriptorSets(descriptorWrites);
    }
}
