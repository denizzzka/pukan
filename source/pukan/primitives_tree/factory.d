module pukan.primitives_tree.factory;

import pukan.mesh: MeshResources;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.frame_builder: FrameBuilder;
import pukan.vulkan.pipelines: DescriptorAllocator, GraphicsPipelineCfg, PipelineFactory, RenderTechnique;

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
            name: T.techniqueName(),
            stages: T.shaderStages(device),
            dynamicStates: [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE],
        ), 10);

        allocator = pipelines.descriptorAllocator(technique);
        graphicsPipelineCfg = pipelines.acquire(technique, renderPass, 1);
    }

    auto create(CTOR_ARGS...)(FrameBuilder frameBuilder, CTOR_ARGS args)
    {
        assert(device);
        auto descriptorsSet = allocator.allocate();

        auto r = new T(device, descriptorsSet, resources, args);

        return r;
    }
}
