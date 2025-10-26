module pukan.gltf.mesh;

import dlib.math;
public import pukan.gltf.loader: BufAccess;
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

struct IndicesBuf
{
    TransferBuffer buffer;
    VkIndexType indexType;

    this(ubyte sz)
    {
        switch(sz)
        {
            case ushort.sizeof: indexType = VK_INDEX_TYPE_UINT16; break;
            case uint.sizeof: indexType = VK_INDEX_TYPE_UINT32; break;
            default: assert(0);
        }
    }
}

class Mesh
{
    string name;
    /*private*/ BufAccess verticesAccessor;
    /*private*/ uint indices_count;
    package IndicesBuf indicesBuffer;
    //TODO: remove or not?
    package TransferBuffer verticesBuffer;
    //TODO: remove:
    /*private*/ TransferBuffer texCoordsBuf;
    /*private*/ VkDescriptorImageInfo* textureDescrImageInfo;
    /*private*/ VkDescriptorSet* descriptorSet;

    private TransferBuffer uniformBuffer;
    private VkDescriptorBufferInfo uboInfo;
    private VkDescriptorBufferInfo bufferInfo;
    private VkWriteDescriptorSet uboWriteDescriptor;

    package this(LogicalDevice device, string name, ref VkDescriptorSet descriptorSet, bool isTextured)
    {
        this.name = name;
        this.descriptorSet = &descriptorSet;

        {
            // TODO: bad idea to allocate a memory buffer only for one uniform buffer,
            // need to allocate more memory then divide it into pieces
            uniformBuffer = device.create!TransferBuffer(UBOContent.sizeof, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);

            ubo.material.baseColorFactor = Vector4f(0, 1, 1, 1);
            ubo.material.renderType.x = isTextured ? 1 : 0;

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

    private ref UBOContent ubo()
    {
        return *cast(UBOContent*) uniformBuffer.cpuBuf.ptr;
    }

    package void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
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

    void refreshBuffers(VkCommandBuffer buf)
    {
        // TODO: move to updateDescriptorSetsAndUniformBuffers?
        uniformBuffer.recordUpload(buf);
    }

    void drawingBufferFilling(TransferBuffer[] buffers, VkCommandBuffer buf, in Matrix4x4f trans)
    {
        assert(verticesAccessor.stride);
        auto vertexBuffer = buffers[verticesAccessor.bufIdx];
        assert(vertexBuffer.cpuBuf.length > 5);

        VkBuffer[2] vkbuffs = [
            vertexBuffer.gpuBuffer.buf.getVal(),
            texCoordsBuf
                ? texCoordsBuf.gpuBuffer.buf.getVal()
                : vertexBuffer.gpuBuffer.buf.getVal(), // fake data to fill out texture coords buffer on non-textured objects
        ];
        VkDeviceSize[2] offsets = [verticesAccessor.offset, 0];
        vkCmdBindVertexBuffers(buf, 0, cast(uint) vkbuffs.length, vkbuffs.ptr, offsets.ptr);

        assert(indices_count);

        vkCmdBindIndexBuffer(buf, indicesBuffer.buffer.gpuBuffer.buf.getVal(), 0, indicesBuffer.indexType);
        vkCmdDrawIndexed(buf, indices_count, 1, 0, 0, 0);
    }
}
