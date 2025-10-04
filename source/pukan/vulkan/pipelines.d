module pukan.vulkan.pipelines;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;

class DefaultPipelineInfoCreator
{
    LogicalDevice device;
    VkPipelineLayout pipelineLayout;
    VkPipelineShaderStageCreateInfo[] shaderStages;

    this(LogicalDevice dev, VkDescriptorSetLayout descriptorSetLayout, VkPipelineShaderStageCreateInfo[] shads)
    {
        device = dev;

        pipelineLayout = createPipelineLayout(device, descriptorSetLayout); //TODO: move out from this class?
        scope(failure) destroy(pipelineLayout);

        shaderStages = shads;

        initDepthStencil();
        initDynamicStates();
        initVertexInputStateCreateInfo();
        initViewportState();

        fillPipelineInfo();
    }

    ~this()
    {
        if(pipelineLayout)
            vkDestroyPipelineLayout(device, pipelineLayout, device.alloc);
    }

    VkPipelineDepthStencilStateCreateInfo depthStencil;

    void initDepthStencil()
    {
        depthStencil = VkPipelineDepthStencilStateCreateInfo(
            sType: VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            depthTestEnable: VK_TRUE,
            depthWriteEnable: VK_TRUE,
            depthCompareOp: VK_COMPARE_OP_LESS,
            depthBoundsTestEnable: VK_FALSE,
            stencilTestEnable: VK_FALSE,
        );
    }

    VkPipelineVertexInputStateCreateInfo vertexInputInfo;

    auto initVertexInputStateCreateInfo()
    {
        static bindingDescriptions = [Vertex.getBindingDescription];
        static attributeDescriptions = Vertex.getAttributeDescriptions;

        vertexInputInfo = VkPipelineVertexInputStateCreateInfo(
            sType: VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            vertexBindingDescriptionCount: cast(uint) bindingDescriptions.length,
            pVertexBindingDescriptions: bindingDescriptions.ptr,
            vertexAttributeDescriptionCount: cast(uint) attributeDescriptions.length,
            pVertexAttributeDescriptions: attributeDescriptions.ptr,
        );
    }

    VkDynamicState[] dynamicStates;
    VkPipelineDynamicStateCreateInfo dynamicState;

    void initDynamicStates()
    {
        dynamicStates = [
            VK_DYNAMIC_STATE_VIEWPORT,
            VK_DYNAMIC_STATE_SCISSOR,
        ];

        dynamicState = VkPipelineDynamicStateCreateInfo(
            sType: VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            dynamicStateCount: cast(uint) dynamicStates.length,
            pDynamicStates: dynamicStates.ptr,
        );
    }

    VkPipelineViewportStateCreateInfo viewportState;

    void initViewportState()
    {
        viewportState = VkPipelineViewportStateCreateInfo(
            sType: VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            viewportCount: 1,
            pViewports: null, // If the viewport state is dynamic, this member is ignored
            scissorCount: 1,
            pScissors: null, // If the scissor state is dynamic, this member is ignored
        );
    }

    VkGraphicsPipelineCreateInfo pipelineCreateInfo;

    void fillPipelineInfo()
    {
        import pukan.vulkan.defaults: colorBlending, inputAssembly, multisampling, rasterizer;

        pipelineCreateInfo = VkGraphicsPipelineCreateInfo(
            sType: VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            stageCount: cast(uint) shaderStages.length,
            pStages: shaderStages.ptr,
            pVertexInputState: &vertexInputInfo,
            pInputAssemblyState: &inputAssembly,
            pViewportState: &viewportState,
            pRasterizationState: &rasterizer,
            pMultisampleState: &multisampling,
            pDepthStencilState: &depthStencil,

            pColorBlendState: &colorBlending,
            pDynamicState: &dynamicState,
            layout: pipelineLayout,
            subpass: 0,
            basePipelineHandle: null, // Optional
            basePipelineIndex: -1, // Optional
        );
    }
}

abstract class Pipelines
{
    LogicalDevice device;
    VkPipeline[] pipelines;
    alias this = pipelines;

    this(LogicalDevice dev)
    {
        device = dev;
    }

    ~this()
    {
        foreach(ref p; pipelines)
            vkDestroyPipeline(device.device, p, device.alloc);
    }
}

class GraphicsPipelines : Pipelines
{
    this(LogicalDevice dev, VkGraphicsPipelineCreateInfo[] infos, RenderPass renderPass)
    {
        super(dev);

        foreach(ref inf; infos)
            inf.renderPass = renderPass.vkRenderPass;

        pipelines.length = infos.length;

        vkCreateGraphicsPipelines(
            device.device,
            null, // pipelineCache
            cast(uint) infos.length,
            infos.ptr,
            device.alloc,
            pipelines.ptr
        ).vkCheck;
    }
}

auto createPipelineLayout(LogicalDevice device, VkDescriptorSetLayout descriptorSetLayout)
{
    // pipeline layout can be used to pass uniform vars into shaders
    VkPipelineLayoutCreateInfo pipelineLayoutCreateInfo = {
        setLayoutCount: 1,
        pSetLayouts: &descriptorSetLayout,
        pushConstantRangeCount: 0, // Optional
        pPushConstantRanges: null, // Optional
    };

    VkPipelineLayout pipelineLayout;
    vkCall(device, &pipelineLayoutCreateInfo, device.alloc, &pipelineLayout);

    return pipelineLayout;
}
