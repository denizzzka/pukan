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
    private DefaultGraphicsPipelineInfoCreator!ShaderInputVertex pipelineInfoCreator;
    GraphicsPipelineCfg graphicsPipelineCfg;

    this(LogicalDevice device, ShaderInfo[] shaderStages, RenderPass renderPass)
    {
        this.device = device;

        auto layoutBindings = shaders.createLayoutBinding(shaderStages);
        poolAndLayout = device.createDescriptorPool(layoutBindings, 2 /*FIXME*/);

        pipelineInfoCreator = new DefaultGraphicsPipelineInfoCreator!ShaderInputVertex(device, [poolAndLayout.descriptorSetLayout], shaderStages, renderPass);
        graphicsPipelineCfg.pipelineLayout = pipelineInfoCreator.pipelineLayout;

        auto pipelineCreateInfo = pipelineInfoCreator.pipelineCreateInfo;
        graphicsPipelineCfg.graphicsPipeline = device.createGraphicsPipelines([pipelineCreateInfo])[0];
    }

    auto create(string filename)
    {
        assert(device);
        auto descriptorSets = device.allocateDescriptorSets(poolAndLayout, 1);

        return loadGlTF2(filename, descriptorSets, device, graphicsPipelineCfg);
    }
}
