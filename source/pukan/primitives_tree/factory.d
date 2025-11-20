module pukan.primitives_tree.factory;

import pukan.scene: Vertex;

struct PrimitivesFactory(T)
{
    import pukan.vulkan;
    import shaders = pukan.vulkan.shaders;
    import pukan.vulkan.frame_builder;

    LogicalDevice device;
    private PoolAndLayoutInfo poolAndLayout;
    private DefaultGraphicsPipelineInfoCreator!Vertex pipelineInfoCreator;
    GraphicsPipelineCfg graphicsPipelineCfg;

    this(LogicalDevice device, ShaderInfo[] shaderStages, RenderPass renderPass)
    {
        this.device = device;

        auto layoutBindings = shaders.createLayoutBinding(shaderStages);
        poolAndLayout = device.createDescriptorPool(layoutBindings, 10 /*FIXME*/);

        pipelineInfoCreator = new DefaultGraphicsPipelineInfoCreator!Vertex(device, [poolAndLayout.descriptorSetLayout], shaderStages, renderPass);
        graphicsPipelineCfg.pipelineLayout = pipelineInfoCreator.pipelineLayout;

        auto pipelineCreateInfo = pipelineInfoCreator.pipelineCreateInfo;
        graphicsPipelineCfg.graphicsPipeline = device.createGraphicsPipelines([pipelineCreateInfo])[0];
    }

    auto create(CTOR_ARGS...)(FrameBuilder frameBuilder, CTOR_ARGS args)
    {
        assert(device);
        auto descriptorsSet = device.allocateDescriptorSet(poolAndLayout);

        auto r = new T(device, [descriptorsSet], args);

        return r;
    }
}
