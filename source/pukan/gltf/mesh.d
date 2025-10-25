module pukan.gltf.mesh;

import dlib.math;
public import pukan.gltf.loader: BufAccess;
import pukan.vulkan;
import pukan.vulkan.bindings;

import pukan.gltf: GlTF;
alias TextureDescr = GlTF.TextureDescr;

//FIXME: remove
alias UBOContent = GlTF.UBOContent;

class Mesh
{
    string name;
    /*private*/ BufAccess indicesAccessor;
    /*private*/ ushort indices_count;
    /*private*/ TextureDescr* textureDescr;
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
            textureDescr.descr,
        ];

        device.updateDescriptorSets(descriptorWrites);
    }

    void refreshBuffers(VkCommandBuffer buf)
    {
        // TODO: move to updateDescriptorSetsAndUniformBuffers?
        uniformBuffer.recordUpload(buf);
    }

    //TODO: buffers seems redundant: accessor can provide this functionality
    void drawingBufferFilling(TransferBuffer[] buffers, VkCommandBuffer buf, in Matrix4x4f trans)
    {
        assert(indices_count);
        assert(indicesAccessor.stride == ushort.sizeof);

        auto indicesBuffer = buffers[indicesAccessor.bufIdx];

        vkCmdBindIndexBuffer(buf, indicesBuffer.gpuBuffer.buf.getVal(), indicesAccessor.offset, VK_INDEX_TYPE_UINT16);
        vkCmdDrawIndexed(buf, indices_count, 1, 0, 0, 0);
    }
}
