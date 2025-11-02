module pukan.gltf.mesh;

import dlib.math;
public import pukan.gltf.loader: BufAccess, BufferPieceOnGPU, ComponentType, bindVertexBuffers, AccessRange;
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
    //~ TransferBuffer buffer;
    BufAccess accessor;
    VkIndexType indexType;

    this(LogicalDevice device, BufAccess acc, ComponentType t)
    {
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

class Mesh
{
    string name;
    package IndicesDescr indices;
    package BufAccess vertices;
    //~ package uint elemCount; /// Number of vertices or indices, depending of mesh type
    /*private*/ VkDescriptorSet* descriptorSet;
    protected BufAccess[2] vertAndTex;

    private TransferBuffer uniformBuffer;
    private VkDescriptorBufferInfo uboInfo;
    private VkDescriptorBufferInfo bufferInfo;
    private VkWriteDescriptorSet uboWriteDescriptor;

    package this(LogicalDevice device, string name, BufAccess vertices, IndicesDescr indices, ref VkDescriptorSet descriptorSet)
    {
        this.name = name;
        this.descriptorSet = &descriptorSet;
        this.vertices = vertices;
        this.indices = indices;

        assert(vertices.viewIdx >= 0);

        vertAndTex = [
            vertices,
            vertices, // fake data to fill out texture coords buffer on non-textured objects
        ];

        {
            // TODO: bad idea to allocate a memory buffer only for one uniform buffer,
            // need to allocate more memory then divide it into pieces
            uniformBuffer = device.create!TransferBuffer(UBOContent.sizeof, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);

            ubo.material.baseColorFactor = Vector4f(0, 1, 1, 1);
            ubo.material.renderType.x = 0; // is not textured

            // Prepare descriptor
            bufferInfo = VkDescriptorBufferInfo(
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
                pBufferInfo: &bufferInfo,
            );
        }
    }

    ~this()
    {
        uniformBuffer.destroy;
    }

    //TODO: remove?
    void uploadImmediate(scope CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        //~ if(indicesBuffer.buffer !is null)
            //~ indicesBuffer.buffer.uploadImmediate(commandPool, commandBuffer);
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

    void refreshBuffers(VkCommandBuffer buf)
    {
        // TODO: move to updateDescriptorSetsAndUniformBuffers?
        uniformBuffer.recordUpload(buf);
    }

    void drawingBufferFilling(BufferPieceOnGPU[] gpuBuffs, VkCommandBuffer buf)
    {
        bindVertexBuffers(gpuBuffs, vertAndTex, buf);

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

///
final class JustColoredMesh : Mesh
{
    private VkDescriptorImageInfo fakeTexture;

    package this(LogicalDevice device, string name, BufAccess vertices, IndicesDescr indices, ref VkDescriptorSet descriptorSet, VkDescriptorImageInfo fakeTexture)
    {
        this.fakeTexture = fakeTexture;

        super(device, name, vertices, indices, descriptorSet);
    }

    override void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
    {
        VkWriteDescriptorSet[] descriptorWrites = [
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
    BufAccess texCoords;
    /*private*/ VkDescriptorImageInfo* textureDescrImageInfo;

    package this(LogicalDevice device, string name, BufAccess vertices, IndicesDescr indices, BufAccess texCoords, ref VkDescriptorSet descriptorSet)
    {
        super(device, name, vertices, indices, descriptorSet);

        this.texCoords = texCoords;
        vertAndTex[1] = this.texCoords;

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
