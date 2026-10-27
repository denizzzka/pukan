module pukan.primitives_tree.factory;

import pukan.scene: Vertex;
import pukan.vulkan;
import pukan.vulkan.frame_builder: FrameBuilder;
import pukan.vulkan.pipelines: GraphicsPipelineCfg, PipelineFactory, RenderTechnique;

struct PrimitivesFactory(T)
{
    LogicalDevice device;
    private PoolAndLayoutInfo poolAndLayout;
    GraphicsPipelineCfg graphicsPipelineCfg;

    this(LogicalDevice device, PipelineFactory pipelines, ShaderInfo[] shaderStages, RenderPass renderPass)
    {
        this.device = device;

        const technique = pipelines.declare(RenderTechnique(
            name: T.stringof,
            stages: shaderStages,
            vertexBindings: Vertex.getBindingDescriptions,
            vertexAttributes: Vertex.getAttributeDescriptions,
        ), 10);

        poolAndLayout = pipelines.poolAndLayout(technique);
        graphicsPipelineCfg = pipelines.acquire(technique, renderPass, 1);
    }

    auto create(CTOR_ARGS...)(FrameBuilder frameBuilder, CTOR_ARGS args)
    {
        assert(device);
        auto descriptorsSet = device.allocateDescriptorSet(poolAndLayout);

        auto r = new T(device, [descriptorsSet], args);

        return r;
    }
}
