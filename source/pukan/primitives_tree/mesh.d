module pukan.primitives_tree.mesh;

import pukan.scene;
import pukan.vulkan;
import pukan.vulkan.bindings;

alias Mesh = TexturedMesh;

class ColoredMesh
{
    Vertex[] vertices;
    ushort[] indices;

    static struct VerticesGPUBuffer
    {
        TransferBuffer vertexBuffer;
        TransferBuffer indicesBuffer;
        uint indicesNum;

        @disable
        this(ref return scope VerticesGPUBuffer rhs) {}

        ~this()
        {
            vertexBuffer.destroy;
            indicesBuffer.destroy;
        }
    }

    ///
    VerticesGPUBuffer uploadMeshToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer) const
    {
        assert(vertices.length > 0);
        assert(indices.length > 0);

        VerticesGPUBuffer r;

        r.vertexBuffer = device.create!TransferBuffer(Vertex.sizeof * vertices.length, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        r.indicesBuffer = device.create!TransferBuffer(ushort.sizeof * indices.length, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
        r.indicesNum = cast(uint) indices.length;

        // Copy vertices to mapped memory
        r.vertexBuffer.cpuBuf[0..$] = cast(void[]) vertices;
        r.indicesBuffer.cpuBuf[0..$] = cast(void[]) indices;

        r.vertexBuffer.uploadImmediate(commandPool, commandBuffer);
        r.indicesBuffer.uploadImmediate(commandPool, commandBuffer);

        return r;
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
