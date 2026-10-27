module pukan.primitives_tree.factory;

import dlib.math: Matrix4x4f;
import pukan.primitives_tree.mesh: TexturedMesh;
import pukan.scene: Vertex;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.frame_builder: FrameBuilder;
import pukan.vulkan.pipelines: DescriptorAllocator, GraphicsPipelineCfg, PipelineFactory, RenderTechnique;

struct PrimitivesFactory(T)
{
    LogicalDevice device;
    private DescriptorAllocator allocator;
    GraphicsPipelineCfg graphicsPipelineCfg;

    this(LogicalDevice device, PipelineFactory pipelines, RenderPass renderPass)
    {
        this.device = device;

        const technique = pipelines.declare(RenderTechnique(
            name: T.stringof,
            stages: shaderStages(device),
            vertexBindings: Vertex.getBindingDescriptions,
            vertexAttributes: Vertex.getAttributeDescriptions,
        ), 10);

        allocator = pipelines.descriptorAllocator(technique);
        graphicsPipelineCfg = pipelines.acquire(technique, renderPass, 1);
    }

    private static ShaderInfo[] shaderStages(LogicalDevice device)
    {
        ShaderInfo[] stages = [
            device.uploadShaderToGPU(
                cast(ubyte[]) import("vert.spv"),
                VK_SHADER_STAGE_VERTEX_BIT,
                null,
                VkPushConstantRange(
                    stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                    offset: 0,
                    size: Matrix4x4f.sizeof,
                ),
            ),
        ];

        static if(is(T == TexturedMesh))
            stages ~= device.uploadShaderToGPU(
                cast(ubyte[]) import("textured_frag.spv"),
                VK_SHADER_STAGE_FRAGMENT_BIT,
                [
                    VkDescriptorSetLayoutBinding(
                        binding: 1,
                        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        descriptorCount: 1,
                        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
                    ),
                ],
            );
        else
            stages ~= device.uploadShaderToGPU(
                cast(ubyte[]) import("colored_frag.spv"),
                VK_SHADER_STAGE_FRAGMENT_BIT,
                null,
            );

        return stages;
    }

    auto create(CTOR_ARGS...)(FrameBuilder frameBuilder, CTOR_ARGS args)
    {
        assert(device);
        auto descriptorsSet = allocator.allocate();

        auto r = new T(device, [descriptorsSet], args);

        return r;
    }
}
