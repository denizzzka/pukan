module pukan.vulkan.pipelines;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;

class DefaultPipelineInfoCreator(Vertex)
{
    LogicalDevice device;
    VkPipelineLayout pipelineLayout;
    VkPipelineShaderStageCreateInfo[] shaderStages;
    VkPushConstantRange[] pushConstantRanges;

    this(LogicalDevice dev, VkDescriptorSetLayout descriptorSetLayout, ShaderInfo[] shads)
    {
        device = dev;

        foreach(ref s; shads)
        {
            shaderStages ~= s.createShaderStageInfo;

            if(s.pushConstantRange.stageFlags)
                pushConstantRanges ~= s.pushConstantRange;
        }

        pipelineLayout = createPipelineLayout(device, descriptorSetLayout, pushConstantRanges); //TODO: move out from this class?
        scope(failure) destroy(pipelineLayout);

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

package mixin template Pipelines()
{
    import std.container.slist;
    private SList!VkPipeline pipelines;

    private void pipelinesDtor()
    {
        foreach(ref p; pipelines)
            vkDestroyPipeline(this.device, p, this.alloc);
    }
}

abstract class Pipelines_DELETE_ME
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

class GraphicsPipelines : Pipelines_DELETE_ME
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

VkPipelineLayout createPipelineLayout(LogicalDevice device, VkDescriptorSetLayout descriptorSetLayout, VkPushConstantRange[] pushConstantRanges)
{
    VkPipelineLayoutCreateInfo pipelineLayoutCreateInfo = {
        setLayoutCount: 1,
        pSetLayouts: &descriptorSetLayout,
        pushConstantRangeCount: cast(uint) pushConstantRanges.length,
        pPushConstantRanges: pushConstantRanges.ptr,
    };

    VkPipelineLayout pipelineLayout;
    vkCall(device, &pipelineLayoutCreateInfo, device.alloc, &pipelineLayout);

    return pipelineLayout;
}
