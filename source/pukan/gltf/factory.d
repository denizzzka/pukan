module pukan.gltf.factory;

import pukan.gltf;

struct GltfFactory
{
    import pukan.vulkan;
    import shaders = pukan.vulkan.shaders;
    import pukan.vulkan.frame_builder;

    LogicalDevice device;
    private PoolAndLayoutInfo poolAndLayout;
    //TODO: contains part of poolAndLayout data. Deduplicate?
    private DefaultGraphicsPipelineInfoCreator!ShaderVertex pipelineInfoCreator;
    GraphicsPipelineCfg graphicsPipelineCfg;

    this(LogicalDevice device, ShaderInfo[] shaderStages, RenderPass renderPass)
    {
        this.device = device;

        auto layoutBindings = shaders.createLayoutBinding(shaderStages);
        poolAndLayout = device.createDescriptorPool(layoutBindings, 20 /*FIXME*/);

        pipelineInfoCreator = new DefaultGraphicsPipelineInfoCreator!ShaderVertex(device, [poolAndLayout.descriptorSetLayout], shaderStages, renderPass);
        graphicsPipelineCfg.pipelineLayout = pipelineInfoCreator.pipelineLayout;

        auto pipelineCreateInfo = pipelineInfoCreator.pipelineCreateInfo;
        graphicsPipelineCfg.graphicsPipeline = device.createGraphicsPipelines([pipelineCreateInfo])[0];
    }

    auto create(string filename)
    {
        assert(device);

        return loadGlTF2(filename, poolAndLayout, device, graphicsPipelineCfg);
    }
}
