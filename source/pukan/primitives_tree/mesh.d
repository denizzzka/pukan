module pukan.primitives_tree.mesh;

import dlib.math: Matrix4x4f, Vector2f, Vector3f;
import pukan.material: Material, MaterialFlag, MaterialFlags, MaterialMode;
import pukan.mesh: Mesh, MeshResources, VertexStream;
import pukan.primitives_tree: DrawablePrimitive;
import pukan.scene: Vertex;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.textures: Texture;

struct LitVertex
{
    Vector3f pos;
    Vector3f normal;
    Vector3f color;
    Vector2f texCoord;
}

private enum hasNormal(VertexT) = __traits(hasMember, VertexT, "normal");

class VertexMesh(VertexT) : Mesh, DrawablePrimitive
{
    VertexT[] vertices;
    ushort[] indices;

    private MeshResources resources;

    private TransferBuffer vertexBuffer;
    private TransferBuffer indicesBuffer;

    this(LogicalDevice device, VkDescriptorSet ds, MeshResources resources, VertexT[] vertices, ushort[] indices)
    {
        super(resources.materials);

        descriptorSet = ds;
        this.resources = resources;
        this.vertices = vertices;
        this.indices = indices;
        frontFace = VK_FRONT_FACE_CLOCKWISE;

        static if(hasNormal!VertexT)
            material = Material(Vector3f(1, 1, 1), MaterialMode.lit, MaterialFlags(MaterialFlag.vertexColor));
        else
            material = Material(Vector3f(1, 1, 1), MaterialMode.unlit, MaterialFlags(MaterialFlag.vertexColor));

        writeMaterial();
        updateDescriptorSets(device, imageInfo(resources.fakeTexture));
    }

    ~this()
    {
        if(vertexBuffer)
            destroy(vertexBuffer);

        if(indicesBuffer)
            destroy(indicesBuffer);
    }

    static string techniqueName()
    {
        static if(hasNormal!VertexT)
            return "lit meshes";
        else
            return "colored meshes";
    }

    static ShaderVertexInput vertexInput()
    {
        VkVertexInputAttributeDescription[] attributes = [
            VkVertexInputAttributeDescription(
                binding: 0,
                location: 0,
                format: VK_FORMAT_R32G32B32_SFLOAT,
                offset: VertexT.pos.offsetof,
            ),
        ];

        static if(hasNormal!VertexT)
        {
            attributes ~= VkVertexInputAttributeDescription(
                binding: 0,
                location: 1,
                format: VK_FORMAT_R32G32B32_SFLOAT,
                offset: VertexT.normal.offsetof,
            );
            attributes ~= VkVertexInputAttributeDescription(
                binding: 0,
                location: 2,
                format: VK_FORMAT_R32G32B32_SFLOAT,
                offset: VertexT.color.offsetof,
            );
            attributes ~= VkVertexInputAttributeDescription(
                binding: 0,
                location: 3,
                format: VK_FORMAT_R32G32_SFLOAT,
                offset: VertexT.texCoord.offsetof,
            );
        }
        else
        {
            attributes ~= VkVertexInputAttributeDescription(
                binding: 0,
                location: 1,
                format: VK_FORMAT_R32G32B32_SFLOAT,
                offset: VertexT.color.offsetof,
            );
            attributes ~= VkVertexInputAttributeDescription(
                binding: 0,
                location: 2,
                format: VK_FORMAT_R32G32_SFLOAT,
                offset: VertexT.texCoord.offsetof,
            );
        }

        return ShaderVertexInput(
            [
                VkVertexInputBindingDescription(
                    binding: 0,
                    stride: VertexT.sizeof,
                    inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
                ),
            ],
            attributes,
        );
    }

    static ShaderInfo[] shaderStages(LogicalDevice device)
    {
        static if(hasNormal!VertexT)
        {
            return [
                device.uploadShaderToGPU(
                    cast(ubyte[]) import("mesh_lit_vert.spv"),
                    VK_SHADER_STAGE_VERTEX_BIT,
                    null,
                    VkPushConstantRange(
                        stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                        offset: 0,
                        size: Matrix4x4f.sizeof,
                    ),
                    vertexInput(),
                ),
                device.uploadShaderToGPU(
                    cast(ubyte[]) import("mesh_lit_frag.spv"),
                    VK_SHADER_STAGE_FRAGMENT_BIT,
                    fragmentBindings(),
                ),
            ];
        }
        else
        {
            return [
                device.uploadShaderToGPU(
                    cast(ubyte[]) import("mesh_static_vert.spv"),
                    VK_SHADER_STAGE_VERTEX_BIT,
                    [
                        VkDescriptorSetLayoutBinding(
                            binding: 2,
                            descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                            descriptorCount: 1,
                            stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                        ),
                    ],
                    VkPushConstantRange(
                        stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                        offset: 0,
                        size: Matrix4x4f.sizeof,
                    ),
                    vertexInput(),
                ),
                device.uploadShaderToGPU(
                    cast(ubyte[]) import("mesh_frag.spv"),
                    VK_SHADER_STAGE_FRAGMENT_BIT,
                    fragmentBindings(),
                ),
            ];
        }
    }

    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        assert(vertices.length > 0);
        assert(indices.length > 0);

        vertexBuffer = device.create!TransferBuffer(VertexT.sizeof * vertices.length, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
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
                stride: VertexT.sizeof,
            ),
        ]);

        vertexCount = cast(uint) vertices.length;

        indexBuffer = indicesBuffer.gpuBuffer;
        indexOffset = 0;
        indexType = VK_INDEX_TYPE_UINT16;
        indexCount = cast(uint) indices.length;
    }

    void drawingBufferFilling(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f trans, VkDescriptorSet frameSet)
    {
        draw(buf, pipeline, trans, frameSet);
    }

    protected void updateDescriptorSets(LogicalDevice device, VkDescriptorImageInfo imageInfo)
    {
        auto materialBufferInfo = materialInfo();

        VkWriteDescriptorSet[] descriptorWrites = [
            bufferWriteDescriptor(descriptorSet, 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, materialBufferInfo),
            imageWriteDescriptor(descriptorSet, 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, imageInfo),
        ];

        static if(!hasNormal!VertexT)
            descriptorWrites ~= bufferWriteDescriptor(descriptorSet, 2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, resources.identityJointsInfo);

        device.updateDescriptorSets(descriptorWrites);
    }

    protected static VkDescriptorImageInfo imageInfo(Texture texture)
    {
        return VkDescriptorImageInfo(
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            imageView: texture.imageView,
            sampler: texture.sampler,
        );
    }

    private static VkDescriptorSetLayoutBinding[] fragmentBindings()
    {
        return [
            VkDescriptorSetLayoutBinding(
                binding: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: 1,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
        ];
    }
}

alias ColoredMesh = VertexMesh!Vertex;
alias LitMesh = VertexMesh!LitVertex;

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

        material.mode = MaterialMode.unlit;
        material.flags = MaterialFlags(MaterialFlag.baseColorTexture);
        writeMaterial();
        updateDescriptorSets(device, imageInfo(texture));
    }

    ~this()
    {
        texture.destroy;
    }

    static string techniqueName() => "textured meshes";
}
