module pukan.gltf.mesh;

import dlib.math;
public import pukan.gltf.loader: BufAccess, BufferPieceOnGPU, ComponentType;
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

struct IndicesBuf
{
    TransferBuffer buffer;
    VkIndexType indexType;
    uint count;

    this(LogicalDevice device, ComponentType t, uint count)
    {
        this.count = count;

        with(ComponentType)
        switch(t)
        {
            case UNSIGNED_SHORT: indexType = VK_INDEX_TYPE_UINT16; break;
            case UNSIGNED_INT: indexType = VK_INDEX_TYPE_UINT32; break;
            default: assert(0);
        }

        import pukan.gltf.loader: componentSizeOf;

        buffer = device.create!TransferBuffer(componentSizeOf(t) * count, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
    }
}

class Mesh
{
    string name;
    package IndicesBuf indicesBuffer;
    package TransferBuffer verticesBuffer;
    /*private*/ VkDescriptorSet* descriptorSet;

    private TransferBuffer uniformBuffer;
    private VkDescriptorBufferInfo uboInfo;
    private VkDescriptorBufferInfo bufferInfo;
    private VkWriteDescriptorSet uboWriteDescriptor;

    //TODO: remove
    private VkDescriptorImageInfo fakeTexture;

    package this(LogicalDevice device, string name, ref VkDescriptorSet descriptorSet, VkDescriptorImageInfo fakeTexture)
    {
        this.name = name;
        this.descriptorSet = &descriptorSet;
        this.fakeTexture = fakeTexture;

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

    void uploadImmediate(scope CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        indicesBuffer.buffer.uploadImmediate(commandPool, commandBuffer);
        verticesBuffer.uploadImmediate(commandPool, commandBuffer);
    }

    package auto calcAABB(ref Boxf box) const
    {
        import std.math: isNaN;

        const slice = cast(Vector3f[]) verticesBuffer.cpuBuf;

        if(box.min.x.isNaN)
        {
            box.min = slice[0];
            box.max = box.min;
        }

        foreach(i; 1 .. slice.length)
            expandAABB(box, slice[i]);
    }

    private ref UBOContent ubo()
    {
        return *cast(UBOContent*) uniformBuffer.cpuBuf.ptr;
    }

    void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
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

    void refreshBuffers(VkCommandBuffer buf)
    {
        // TODO: move to updateDescriptorSetsAndUniformBuffers?
        uniformBuffer.recordUpload(buf);
    }

    void drawingBufferFilling(VkCommandBuffer buf, in Matrix4x4f trans)
    {
        VkBuffer[2] vkbuffs = [
            verticesBuffer.gpuBuffer.buf.getVal(),
            verticesBuffer.gpuBuffer.buf.getVal(), // fake data to fill out texture coords buffer on non-textured objects
        ];
        immutable VkDeviceSize[2] offsets = [0, 0];
        vkCmdBindVertexBuffers(buf, 0, cast(uint) vkbuffs.length, vkbuffs.ptr, offsets.ptr);

        assert(indicesBuffer.count);
        vkCmdBindIndexBuffer(buf, indicesBuffer.buffer.gpuBuffer.buf.getVal(), 0, indicesBuffer.indexType);
        vkCmdDrawIndexed(buf, indicesBuffer.count, 1, 0, 0, 0);
    }
}

//TODO: implement non-textured Mesh
final class TexturedMesh : Mesh
{
    /*private*/ TransferBuffer texCoordsBuf;
    /*private*/ VkDescriptorImageInfo* textureDescrImageInfo;

    package this(LogicalDevice device, string name, ref VkDescriptorSet descriptorSet)
    {
        VkDescriptorImageInfo unused_fake_texture;

        super(device, name, descriptorSet, unused_fake_texture);
        ubo.material.renderType.x = 1; // is textured
    }

    override void uploadImmediate(scope CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        super.uploadImmediate(commandPool, commandBuffer);
        texCoordsBuf.uploadImmediate(commandPool, commandBuffer);
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

    override void drawingBufferFilling(VkCommandBuffer buf, in Matrix4x4f trans)
    {
        VkBuffer[2] vkbuffs = [
            verticesBuffer.gpuBuffer.buf.getVal(),
            texCoordsBuf.gpuBuffer.buf.getVal(),
        ];
        immutable VkDeviceSize[2] offsets = [0, 0];
        vkCmdBindVertexBuffers(buf, 0, cast(uint) vkbuffs.length, vkbuffs.ptr, offsets.ptr);

        assert(indicesBuffer.count);
        vkCmdBindIndexBuffer(buf, indicesBuffer.buffer.gpuBuffer.buf.getVal(), 0, indicesBuffer.indexType);
        vkCmdDrawIndexed(buf, indicesBuffer.count, 1, 0, 0, 0);
    }
}
