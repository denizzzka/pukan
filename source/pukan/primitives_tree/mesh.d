module pukan.primitives_tree.mesh;

import dlib.math: Matrix4x4f;
import pukan.mesh: Mesh, MeshResources, VertexStream;
import pukan.primitives_tree: DrawablePrimitive;
import pukan.scene: Vertex;
import pukan.vulkan;
import pukan.vulkan.bindings;

class ColoredMesh : Mesh, DrawablePrimitive
{
    Vertex[] vertices;
    ushort[] indices;

    private MeshResources resources;
    private size_t materialSlot;

    private TransferBuffer vertexBuffer;
    private TransferBuffer indicesBuffer;

    this(LogicalDevice device, VkDescriptorSet ds, MeshResources resources, Vertex[] vertices, ushort[] indices)
    {
        descriptorSet = ds;
        this.resources = resources;
        this.vertices = vertices;
        this.indices = indices;

        materialSlot = resources.materials.addSlot();
        resources.materials.content(materialSlot).material.renderType.x = 0;

        updateDescriptorSets(device, imageInfo(resources.fakeTexture));
    }

    ~this()
    {
        if(vertexBuffer)
            destroy(vertexBuffer);

        if(indicesBuffer)
            destroy(indicesBuffer);
    }

    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        assert(vertices.length > 0);
        assert(indices.length > 0);

        vertexBuffer = device.create!TransferBuffer(Vertex.sizeof * vertices.length, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        indicesBuffer = device.create!TransferBuffer(ushort.sizeof * indices.length, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);

        vertexBuffer.cpuBuf[0..$] = cast(void[]) vertices;
        indicesBuffer.cpuBuf[0..$] = cast(void[]) indices;

        commandPool.recordOneTimeAndSubmit(commandBuffer, (buf) {
            vertexBuffer.recordUpload(buf);
            indicesBuffer.recordUpload(buf);
            resources.materials.recordUpload(buf);
        });

        setStreams([
            VertexStream(
                buffer: vertexBuffer.gpuBuffer,
                offset: 0,
                size: vertexBuffer.length,
                stride: Vertex.sizeof,
            ),
        ]);

        vertexCount = cast(uint) vertices.length;

        indexBuffer = indicesBuffer.gpuBuffer;
        indexOffset = 0;
        indexType = VK_INDEX_TYPE_UINT16;
        indexCount = cast(uint) indices.length;
    }

    void drawingBufferFilling(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f trans)
    {
        draw(buf, pipeline, trans);
    }

    private void setMaterialMode(int mode)
    {
        resources.materials.content(materialSlot).material.renderType.x = mode;
    }

    private void updateDescriptorSets(LogicalDevice device, VkDescriptorImageInfo imageInfo)
    {
        auto uboInfo = resources.materials.info(materialSlot);

        VkWriteDescriptorSet[] descriptorWrites = [
            bufferWriteDescriptor(descriptorSet, 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, uboInfo),
            imageWriteDescriptor(descriptorSet, 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, imageInfo),
            bufferWriteDescriptor(descriptorSet, 2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, resources.identityJointsInfo),
        ];

        device.updateDescriptorSets(descriptorWrites);
    }

    private static VkDescriptorImageInfo imageInfo(Texture texture)
    {
        return VkDescriptorImageInfo(
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            imageView: texture.imageView,
            sampler: texture.sampler,
        );
    }
}

class TexturedMesh : ColoredMesh
{
    Texture texture;

    this(
        LogicalDevice device,
        VkDescriptorSet ds,
        MeshResources resources,
        Vertex[] vertices,
        ushort[] indices,
        Texture texture,
    )
    {
        this.texture = texture;
        super(device, ds, resources, vertices, indices);

        setMaterialMode(1);
        updateDescriptorSets(device, imageInfo(texture));
    }

    ~this()
    {
        texture.destroy;
    }
}
