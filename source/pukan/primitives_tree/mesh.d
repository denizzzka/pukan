module pukan.primitives_tree.mesh;

import pukan.scene;
import pukan.vulkan;
import pukan.vulkan.bindings;

class ColoredMesh : DrawableByVulkan
{
    Vertex[] vertices;
    ushort[] indices;

    static struct VerticesGPUBuffer
    {
        TransferBuffer vertexBuffer;
        TransferBuffer indicesBuffer;

        @disable
        this(ref return scope VerticesGPUBuffer rhs) {}

        ~this()
        {
            vertexBuffer.destroy;
            indicesBuffer.destroy;
        }
    }

    VerticesGPUBuffer r;
    alias this = r;

    ///
    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        assert(vertices.length > 0);
        assert(indices.length > 0);

        r.vertexBuffer = device.create!TransferBuffer(Vertex.sizeof * vertices.length, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        r.indicesBuffer = device.create!TransferBuffer(ushort.sizeof * indices.length, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);

        // Copy vertices to mapped memory
        r.vertexBuffer.cpuBuf[0..$] = cast(void[]) vertices;
        r.indicesBuffer.cpuBuf[0..$] = cast(void[]) indices;

        r.vertexBuffer.uploadImmediate(commandPool, commandBuffer);
        r.indicesBuffer.uploadImmediate(commandPool, commandBuffer);
    }

    void updateDescriptorSet(FrameBuilder frameBuilder, DescriptorPool descriptorPool, VkDescriptorSet dstDescriptorSet)
    {
        VkDescriptorBufferInfo bufferInfo = {
            buffer: frameBuilder.uniformBuffer.gpuBuffer,
            offset: 0,
            range: WorldTransformationUniformBuffer.sizeof,
        };

        VkWriteDescriptorSet[] descriptorWrites = [
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: dstDescriptorSet,
                dstBinding: 0,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                pBufferInfo: &bufferInfo,
            ),
        ];

        descriptorPool.updateSets(descriptorWrites);
    }

    import dlib.math: Matrix4x4f;

    void drawingBufferFilling(VkCommandBuffer buf, VkPipeline graphicsPipeline, VkPipelineLayout pipelineLayout, VkDescriptorSet[] descriptorSets, ref Matrix4x4f trans) //const
    {
        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, graphicsPipeline);

        auto vertexBuffers = [vertexBuffer.gpuBuffer.buf];
        VkDeviceSize[] offsets = [VkDeviceSize(0)];

        vkCmdPushConstants(buf, pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, cast(uint) trans.sizeof, cast(void*) &trans);

        vkCmdBindVertexBuffers(buf, 0, 1, vertexBuffers.ptr, offsets.ptr);
        vkCmdBindIndexBuffer(buf, indicesBuffer.gpuBuffer.buf, 0, VK_INDEX_TYPE_UINT16);
        vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, cast(uint) descriptorSets.length, descriptorSets.ptr, 0, null);

        vkCmdDrawIndexed(buf, cast(uint) indices.length, 1, 0, 0, 0);
    }
}

class TexturedMesh : ColoredMesh
{
    //TODO: move to mesh-in-GPU descriptor
    Texture texture;

    ~this()
    {
        texture.destroy;
    }

    void updateTextureDescriptorSet(
        LogicalDevice device,
        FrameBuilder frameBuilder,
        CommandPool commandPool,
        scope VkCommandBuffer commandBuffer,
        DescriptorPool descriptorPool,
        VkDescriptorSet dstDescriptorSet,
    ) //TODO: const
    {
        import pukan.scene: WorldTransformationUniformBuffer;

        texture = device.create!Texture(commandPool, commandBuffer);

        VkDescriptorBufferInfo bufferInfo = {
            buffer: frameBuilder.uniformBuffer.gpuBuffer,
            offset: 0,
            range: WorldTransformationUniformBuffer.sizeof,
        };

        VkDescriptorImageInfo imageInfo = {
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            imageView: texture.imageView,
            sampler: texture.sampler,
        };

        VkWriteDescriptorSet[] descriptorWrites = [
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: dstDescriptorSet,
                dstBinding: 0,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                pBufferInfo: &bufferInfo,
            ),
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: dstDescriptorSet,
                dstBinding: 1,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                pImageInfo: &imageInfo,
            )
        ];

        descriptorPool.updateSets(descriptorWrites);
    }
}
