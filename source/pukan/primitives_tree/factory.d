module pukan.primitives_tree.factory;

import dlib.math: Matrix4x4f;
import pukan.mesh: MeshResources;
import pukan.scene: Vertex;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.frame_builder: FrameBuilder;
import pukan.vulkan.pipelines: DescriptorAllocator, GraphicsPipelineCfg, PipelineFactory, RenderTechnique;

private ShaderVertexInput vertexInput()
{
    return ShaderVertexInput(
        [
            VkVertexInputBindingDescription(
                binding: 0,
                stride: Vertex.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
        ],
        [
            VkVertexInputAttributeDescription(
                binding: 0,
                location: 0,
                format: VK_FORMAT_R32G32B32_SFLOAT,
                offset: Vertex.pos.offsetof,
            ),
            VkVertexInputAttributeDescription(
                binding: 0,
                location: 1,
                format: VK_FORMAT_R32G32B32_SFLOAT,
                offset: Vertex.color.offsetof,
            ),
            VkVertexInputAttributeDescription(
                binding: 0,
                location: 2,
                format: VK_FORMAT_R32G32_SFLOAT,
                offset: Vertex.texCoord.offsetof,
            ),
        ],
    );
}

struct PrimitivesFactory(T)
{
    LogicalDevice device;
    private DescriptorAllocator allocator;
    private MeshResources resources;
    GraphicsPipelineCfg graphicsPipelineCfg;

    this(LogicalDevice device, PipelineFactory pipelines, MeshResources resources, RenderPass renderPass)
    {
        this.device = device;
        this.resources = resources;

        const technique = pipelines.declare(RenderTechnique(
            name: T.stringof,
            stages: shaderStages(device),
            dynamicStates: [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE],
        ), 10);

        allocator = pipelines.descriptorAllocator(technique);
        graphicsPipelineCfg = pipelines.acquire(technique, renderPass, 1);
    }

    private static ShaderInfo[] shaderStages(LogicalDevice device)
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
                [
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
                ],
            ),
        ];
    }

    auto create(CTOR_ARGS...)(FrameBuilder frameBuilder, CTOR_ARGS args)
    {
        assert(device);
        auto descriptorsSet = allocator.allocate();

        auto r = new T(device, descriptorsSet, resources, args);

        return r;
    }
}
