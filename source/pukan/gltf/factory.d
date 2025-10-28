module pukan.gltf.factory;

import pukan.gltf;
import pukan.vulkan;

class PipelineInfoCreator : DefaultGraphicsPipelineInfoCreator!ShaderVertex
{
    import pukan.vulkan.bindings;
    import pukan.vulkan.renderpass;

    this(LogicalDevice dev, VkDescriptorSetLayout[] descriptorSetLayouts, ShaderInfo[] shads, RenderPass renderPass)
    {
        rasterizerInfo.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;

        super(dev, descriptorSetLayouts, shads, renderPass);
    }
}

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

        pipelineInfoCreator = new PipelineInfoCreator(device, [poolAndLayout.descriptorSetLayout], shaderStages, renderPass);
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
