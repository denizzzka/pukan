module pukan.primitives_tree;

import pukan.scene: Vertex;
import std.variant: Algebraic;
import dlib.math: Matrix4x4f;

struct Node
{
    Algebraic!(
        Bone,
        Mesh,
        PrimitivesTree,
    ) payload;

    Node[] children;
}

class PrimitivesTree
{
    Node root;
}

/// Represents the translation of an node relative to the ancestor bone node
alias Bone = Matrix4x4f;

//TODO: implement class for non-textured meshes
class Mesh
{
    import pukan.scene: Scene;
    import pukan.vulkan;
    import pukan.vulkan.bindings;
    import pukan.vulkan.textures: Texture;

    Vertex[] vertices;
    ushort[] indices;
    //TODO: move to mesh-in-GPU descriptor
    Texture texture;

    ~this()
    {
        texture.destroy;
    }

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
    VerticesGPUBuffer uploadMeshToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
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

    void setTextureDescriptors(Scene scene, LogicalDevice device, FrameBuilder frameBuilder, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
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
                dstSet: scene.descriptorSets[0 /*TODO: frame number*/],
                dstBinding: 0,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                pBufferInfo: &bufferInfo,
            ),
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: scene.descriptorSets[0 /*TODO: frame number*/],
                dstBinding: 1,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                pImageInfo: &imageInfo,
            )
        ];

        scene.descriptorPool.updateSets(descriptorWrites);
    }
}
