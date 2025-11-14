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

class Mesh
{
    string name;
    package UploadedVertices vert;
    alias this = vert;
    /*private*/ VkDescriptorSet* descriptorSet;

    private TransferBuffer uniformBuffer;
    private VkDescriptorBufferInfo uboInfo;
    private VkWriteDescriptorSet uboWriteDescriptor;
    private VkWriteDescriptorSet jointsUboWriteDescr;

    package this(LogicalDevice device, string name, UploadedVertices vert, ref VkDescriptorSet descriptorSet, ref VkDescriptorBufferInfo jointsUboInfo)
    {
        this.name = name;
        this.descriptorSet = &descriptorSet;
        this.vert = vert;

        assert(vertices.viewIdx >= 0);

        if(vert.texCoords.viewIdx < 0)
            this.vert.texCoords = vert.vertices; // fake data to fill out texture coords buffer on non-textured objects

        if(vert.weights.viewIdx < 0)
        {
            this.vert.joints = vert.vertices; // ditto
            this.vert.weights = this.vert.joints; // ditto
        }

        {
            // TODO: bad idea to allocate a memory buffer only for one uniform buffer,
            // need to allocate more memory then divide it into pieces
            uniformBuffer = device.create!TransferBuffer(UBOContent.sizeof, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);

            ubo.material.baseColorFactor = Vector4f(0, 1, 1, 1);
            ubo.material.renderType.x = 0; // is not textured

            // Prepare descriptor
            uboInfo = VkDescriptorBufferInfo(
                buffer: uniformBuffer.gpuBuffer,
                offset: 0,
                range: UBOContent.sizeof,
            );

            uboWriteDescriptor = VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: descriptorSet,
                dstBinding: 0,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                pBufferInfo: &uboInfo,
            );

            jointsUboWriteDescr = VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: descriptorSet,
                dstBinding: 0,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                pBufferInfo: &jointsUboInfo,
            );
        }
    }

    ~this()
    {
        uniformBuffer.destroy;
    }

    void uploadImmediate(scope CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        uniformBuffer.uploadImmediate(commandPool, commandBuffer);
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
        return *cast(UBOContent*) uniformBuffer.cpuBuf.ptr;
    }

    abstract void updateDescriptorSetsAndUniformBuffers(LogicalDevice device);

    //TODO: remove?
    void refreshBuffers(VkCommandBuffer buf)
    {
    }

    void drawingBufferFilling(BufferPieceOnGPU[] gpuBuffs, VkCommandBuffer buf)
    {
        bindVertexBuffers(gpuBuffs, vert.allBuffers, buf);

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

private void bindVertexBuffers(BufferPieceOnGPU[] gpuBuffs, in BufAccess[] accessors, VkCommandBuffer cmdBuf)
in(gpuBuffs.length > 0)
{
    const len = cast(uint) accessors.length;
    assert(len > 0);

    auto buffers = new VkBuffer[len];
    auto offsets = new VkDeviceSize[len];
    auto sizes = new VkDeviceSize[len];
    auto strides = new VkDeviceSize[len];

    foreach(i, const acc; accessors)
    {
        assert(acc.viewIdx >= 0);
        assert(acc.stride > 0);

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

    package this(LogicalDevice device, string name, UploadedVertices vert, ref VkDescriptorSet descriptorSet, VkDescriptorImageInfo fakeTexture, VkDescriptorBufferInfo jointsUboInfo)
    {
        this.fakeTexture = fakeTexture;

        super(device, name, vert, descriptorSet, jointsUboInfo);
    }

    override void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
    {
        VkWriteDescriptorSet[] descriptorWrites = [
            jointsUboWriteDescr,
            uboWriteDescriptor,
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: *descriptorSet,
                dstBinding: 1,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                pImageInfo: &fakeTexture,
            ),
        ];

        device.updateDescriptorSets(descriptorWrites);
    }
}

///
final class TexturedMesh : Mesh
{
    /*private*/ VkDescriptorImageInfo* textureDescrImageInfo;

    package this(LogicalDevice device, string name, UploadedVertices vert, ref VkDescriptorSet descriptorSet, VkDescriptorBufferInfo jointsUboInfo)
    {
        super(device, name, vert, descriptorSet, jointsUboInfo);

        ubo.material.renderType.x = 1; // is textured
    }

    override void uploadImmediate(scope CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        super.uploadImmediate(commandPool, commandBuffer);
    }

    override void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
    {
        //TODO: store all these VkWriteDescriptorSet in one array to best updating performance?
        VkWriteDescriptorSet[] descriptorWrites = [
            jointsUboWriteDescr,
            uboWriteDescriptor,
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: *descriptorSet,
                dstBinding: 1,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                pImageInfo: textureDescrImageInfo,
            ),
        ];

        device.updateDescriptorSets(descriptorWrites);
    }
}
