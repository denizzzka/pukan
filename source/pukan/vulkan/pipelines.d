module pukan.vulkan.pipelines;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;

class DefaultGraphicsPipelineInfoCreator(Vertex)
{
    LogicalDevice device;
    VkPipelineLayout pipelineLayout;
    VkPipelineShaderStageCreateInfo[] shaderStages;
    VkPushConstantRange[] pushConstantRanges;

    this(LogicalDevice dev, VkDescriptorSetLayout[] descriptorSetLayouts, ShaderInfo[] shads, RenderPass renderPass)
    {
        device = dev;

        foreach(ref s; shads)
        {
            shaderStages ~= s.createShaderStageInfo;

            if(s.pushConstantRange.stageFlags)
                pushConstantRanges ~= s.pushConstantRange;
        }

        pipelineLayout = createPipelineLayout(device, descriptorSetLayouts, pushConstantRanges); //TODO: move out from this class?
        scope(failure) destroy(pipelineLayout);

        initDepthStencil();
        initDynamicStates();
        initVertexInputStateCreateInfo();
        initViewportState();

        fillPipelineInfo(renderPass);
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
        static bindingDescriptions = Vertex.getBindingDescriptions;
        static attributeDescriptions = Vertex.getAttributeDescriptions;

        vertexInputInfo = VkPipelineVertexInputStateCreateInfo(
            sType: VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            vertexBindingDescriptionCount: cast(uint) bindingDescriptions.length,
            pVertexBindingDescriptions: bindingDescriptions.ptr,
            vertexAttributeDescriptionCount: cast(uint) attributeDescriptions.length,
            pVertexAttributeDescriptions: attributeDescriptions.ptr,
        );
    }

    VkDynamicState[] dynamicStates = [
        VK_DYNAMIC_STATE_VIEWPORT,
        VK_DYNAMIC_STATE_SCISSOR,
    ];

    VkPipelineDynamicStateCreateInfo dynamicStateInfo;

    void initDynamicStates()
    {
        dynamicStateInfo = VkPipelineDynamicStateCreateInfo(
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

    VkPipelineRasterizationStateCreateInfo rasterizerInfo = {
        sType: VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        rasterizerDiscardEnable: VK_FALSE,
        depthClampEnable: VK_FALSE,
        polygonMode: VK_POLYGON_MODE_FILL,
        lineWidth: 1.0f,
        cullMode: VK_CULL_MODE_BACK_BIT,
        frontFace: VK_FRONT_FACE_CLOCKWISE,
        depthBiasEnable: VK_FALSE,
        depthBiasConstantFactor: 0.0f, // Optional
        depthBiasClamp: 0.0f, // Optional
        depthBiasSlopeFactor: 0.0f, // Optional
    };

    VkGraphicsPipelineCreateInfo pipelineCreateInfo;

    void fillPipelineInfo(ref RenderPass renderPass)
    {
        import pukan.vulkan.defaults: colorBlending, inputAssembly, multisampling;

        pipelineCreateInfo = VkGraphicsPipelineCreateInfo(
            sType: VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            stageCount: cast(uint) shaderStages.length,
            pStages: shaderStages.ptr,
            pVertexInputState: &vertexInputInfo,
            pInputAssemblyState: &inputAssembly,
            pViewportState: &viewportState,
            pRasterizationState: &rasterizerInfo,
            pMultisampleState: &multisampling,
            pDepthStencilState: &depthStencil,

            pColorBlendState: &colorBlending,
            pDynamicState: &dynamicStateInfo,
            layout: pipelineLayout,
            renderPass: renderPass.vkRenderPass,
            subpass: 0,
            basePipelineHandle: null, // Optional
            basePipelineIndex: -1, // Optional
        );
    }
}

package mixin template Pipelines()
{
    private VkPipeline[] pipelines;

    private void pipelinesDtor()
    {
        foreach(ref p; pipelines)
            vkDestroyPipeline(this.device, p, this.alloc);
    }

    VkPipeline[] createGraphicsPipelines(VkGraphicsPipelineCreateInfo[] infos)
    out(r; r.length == infos.length)
    {
        size_t prevLen = pipelines.length;
        pipelines.length += infos.length;

        vkCreateGraphicsPipelines(
            this.device,
            null, // pipelineCache
            cast(uint) infos.length,
            infos.ptr,
            this.alloc,
            &pipelines[prevLen]
        ).vkCheck;

        return pipelines[prevLen .. $];
    }
}

VkPipelineLayout createPipelineLayout(LogicalDevice device, VkDescriptorSetLayout[] descriptorSetLayouts, VkPushConstantRange[] pushConstantRanges)
{
    VkPipelineLayoutCreateInfo pipelineLayoutCreateInfo = {
        setLayoutCount: cast(uint) descriptorSetLayouts.length,
        pSetLayouts: descriptorSetLayouts.ptr,
        pushConstantRangeCount: cast(uint) pushConstantRanges.length,
        pPushConstantRanges: pushConstantRanges.ptr,
    };

    VkPipelineLayout pipelineLayout;
    vkCall(device, &pipelineLayoutCreateInfo, device.alloc, &pipelineLayout);

    return pipelineLayout;
}

struct GraphicsPipelineCfg
{
    VkPipeline graphicsPipeline;
    VkPipelineLayout pipelineLayout;
}
