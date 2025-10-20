module pukan.primitives_tree.mesh;

import pukan.scene;
import pukan.vulkan;
import pukan.vulkan.bindings;

class Mesh
{
    Vertex[] vertices;
    ushort[] indices;

    this(Vertex[] vertices, ushort[] indices)
    {
        this.vertices = vertices;
        this.indices = indices;
    }
}

class ColoredMesh : Mesh
{
    VkDescriptorSet[] descriptorSets;

    this(VkDescriptorSet[] ds, Vertex[] vertices, ushort[] indices)
    {
        descriptorSets = ds;
        super(vertices, indices);
    }

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

    void updateDescriptorSets(LogicalDevice device)
    {
    }

    void refreshBuffers(VkCommandBuffer buf)
    {
    }

    import dlib.math: Matrix4x4f;

    void drawingBufferFilling(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f trans) //const
    {
        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);

        VkDeviceSize[] offsets = [VkDeviceSize(0)];

        vkCmdPushConstants(buf, pipeline.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, cast(uint) trans.sizeof, cast(void*) &trans);

        vkCmdBindVertexBuffers(buf, 0, 1, &(vertexBuffer.gpuBuffer.buf.getVal()), offsets.ptr);
        vkCmdBindIndexBuffer(buf, indicesBuffer.gpuBuffer.buf, 0, VK_INDEX_TYPE_UINT16);
        vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipelineLayout, 0, cast(uint) descriptorSets.length, descriptorSets.ptr, 0, null);

        vkCmdDrawIndexed(buf, cast(uint) indices.length, 1, 0, 0, 0);
    }
}

class TexturedMesh : ColoredMesh
{
    Texture texture;

    this(VkDescriptorSet[] ds, Vertex[] vertices, ushort[] indices, Texture texture)
    {
        this.texture = texture;
        super(ds, vertices, indices);
    }

    ~this()
    {
        texture.destroy;
    }

    override void updateDescriptorSets(LogicalDevice device)
    {
        VkDescriptorImageInfo imageInfo = {
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            imageView: texture.imageView,
            sampler: texture.sampler,
        };

        assert(descriptorSets.length == 1);

        VkWriteDescriptorSet[] descriptorWrites = [
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: descriptorSets[0],
                dstBinding: 1,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                pImageInfo: &imageInfo,
            )
        ];

        device.updateDescriptorSets(descriptorWrites);
    }
}
