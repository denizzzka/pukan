module pukan.graphics.g3d.primitives_tree.factory;

import pukan.graphics.g3d.mesh: MeshResources;
import pukan.vulkan.bindings;
import pukan.vulkan.frame_builder: FrameBuilder;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.pipelines: DescriptorAllocator, GraphicsPipelineCfg, PipelineFactory, RenderTechnique;
import pukan.vulkan.renderpass: RenderPass;
import pukan.vulkan.requirements: Requirement;
import std.meta: AliasSeq;

struct PrimitivesFactory(T)
{
    private alias requirements = AliasSeq!(
        Requirement!(VkPhysicalDeviceExtendedDynamicStateFeaturesEXT.extendedDynamicState),
    );

    LogicalDevice device;
    private DescriptorAllocator allocator;
    private MeshResources resources;
    GraphicsPipelineCfg graphicsPipelineCfg;
    GraphicsPipelineCfg shadowGraphicsPipelineCfg;

    this(LogicalDevice device, PipelineFactory pipelines, MeshResources resources,
        RenderPass renderPass, RenderPass shadowPass)
    {
        this.device = device;
        this.resources = resources;

        const technique = pipelines.declare(RenderTechnique(
            name: T.techniqueName(),
            stages: T.shaderStages(),
            dynamicStates: [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE, VK_DYNAMIC_STATE_FRONT_FACE],
        ), 10);

        allocator = pipelines.descriptorAllocator(technique);
        graphicsPipelineCfg = pipelines.acquire(technique, renderPass, 1);

        const shadowTechnique = pipelines.declare(RenderTechnique(
            name: T.techniqueName() ~ " shadow",
            stages: T.shadowShaderStages(),
            dynamicStates: [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE, VK_DYNAMIC_STATE_FRONT_FACE],
        ), 1);

        shadowGraphicsPipelineCfg = pipelines.acquire(shadowTechnique, shadowPass, 0);
    }

    auto create(CTOR_ARGS...)(FrameBuilder frameBuilder, CTOR_ARGS args)
    {
        assert(device);
        auto descriptorsSet = allocator.allocate();

        auto r = new T(device, descriptorsSet, resources, args);

        return r;
    }
}
