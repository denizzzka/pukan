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

    this(
        LogicalDevice dev,
        VkDescriptorSetLayout[] descriptorSetLayouts,
        ShaderInfo[] shads,
        RenderPass renderPass,
        uint subpass = 0,
    )
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

        fillPipelineInfo(renderPass, subpass);
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

    void fillPipelineInfo(ref RenderPass renderPass, uint subpass)
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
            subpass: subpass,
            basePipelineHandle: null, // Optional
            basePipelineIndex: -1, // Optional
        );
    }
}

package mixin template Pipelines()
{
    private VkPipeline[] pipelines;
    private VkPipelineLayout[] pipelineLayouts;

    /// Registers a pipeline layout to be destroyed after all pipelines
    void registerPipelineLayout(VkPipelineLayout layout)
    {
        pipelineLayouts ~= layout;
    }

    private void pipelinesDtor()
    {
        foreach(ref p; pipelines)
            vkDestroyPipeline(this.device, p, this.alloc);

        foreach(layout; pipelineLayouts)
            vkDestroyPipelineLayout(this.device, layout, this.alloc);
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

    VkPipeline[] createComputePipelines(VkComputePipelineCreateInfo[] infos)
    out(r; r.length == infos.length)
    {
        size_t prevLen = pipelines.length;
        pipelines.length += infos.length;

        vkCreateComputePipelines(
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

struct TechniqueId
{
    uint value;
}

struct RenderTargetId
{
    uint value;
}

struct PipelineKey
{
    TechniqueId technique;
    RenderTargetId target;

    size_t toHash() const nothrow @safe
    {
        return hashOf(technique.value, hashOf(target.value));
    }

    bool opEquals(ref const PipelineKey rhs) const nothrow @safe
    {
        return technique.value == rhs.technique.value &&
            target.value == rhs.target.value;
    }
}

struct FixedState
{
    VkPrimitiveTopology topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkCullModeFlags cullMode = VK_CULL_MODE_BACK_BIT;
    VkFrontFace frontFace = VK_FRONT_FACE_CLOCKWISE;
    VkBool32 depthTestEnable = VK_TRUE;
    VkBool32 depthWriteEnable = VK_TRUE;
    VkCompareOp depthCompareOp = VK_COMPARE_OP_LESS;
    VkBool32 blendEnable = VK_FALSE;
}

struct RenderTechnique
{
    string name;
    ShaderInfo[] stages;
    VkVertexInputBindingDescription[] vertexBindings;
    VkVertexInputAttributeDescription[] vertexAttributes;
    FixedState state;
    VkDynamicState[] dynamicStates;
}

//TODO: move to pukan: pool growth is engine policy, not a Vulkan wrapper
/// Allocates descriptor sets, adding a pool when the current one is full
final class DescriptorAllocator
{
    private LogicalDevice device;
    private VkDescriptorSetLayout layout;
    private VkDescriptorSetLayoutBinding[] bindings;
    private uint setsPerPool;
    private VkDescriptorPool[] pools;
    private uint allocatedInCurrentPool;

    this(
        LogicalDevice device,
        VkDescriptorSetLayout layout,
        VkDescriptorSetLayoutBinding[] bindings,
        uint setsPerPool = 16,
    )
    in(setsPerPool > 0)
    {
        this.device = device;
        this.layout = layout;
        this.bindings = bindings;
        this.setsPerPool = setsPerPool;
    }

    VkDescriptorSet allocate()
    {
        if(pools.length == 0 || allocatedInCurrentPool == setsPerPool)
            addPool();

        VkDescriptorSetAllocateInfo info = {
            sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            descriptorPool: pools[$ - 1],
            descriptorSetCount: 1,
            pSetLayouts: &layout,
        };

        while(true)
        {
            VkDescriptorSet set;
            const result = vkAllocateDescriptorSets(device, &info, &set);

            if(result == VK_SUCCESS)
            {
                ++allocatedInCurrentPool;
                return set;
            }

            if(result != VK_ERROR_OUT_OF_POOL_MEMORY && result != VK_ERROR_FRAGMENTED_POOL)
                result.vkCheck;

            addPool();
            info.descriptorPool = pools[$ - 1];
        }
    }

    private void addPool()
    {
        auto poolAndLayout = device.createDescriptorPool(layout, bindings, setsPerPool);
        pools ~= poolAndLayout.descriptorPool;
        allocatedInCurrentPool = 0;
    }
}

//TODO: move to pukan: technique and pipeline caching is engine policy, not a Vulkan wrapper
/// Creates pipelines once per technique and render target
final class PipelineFactory
{
    private struct Technique
    {
        RenderTechnique description;
        ShaderInfo[] stages;
        VkDescriptorSetLayout setLayout;
        VkPipelineLayout pipelineLayout;
        DescriptorAllocator allocator;
    }

    private struct RenderTarget
    {
        VkRenderPass renderPass;
        uint subpass;
    }

    private LogicalDevice device;
    private Technique[] techniques;
    private RenderTarget[] targets;
    private GraphicsPipelineCfg[PipelineKey] cache;

    this(LogicalDevice device)
    {
        this.device = device;
    }

    TechniqueId declare(RenderTechnique technique, uint setsPerPool = 16)
    {
        Technique entry;
        entry.description = technique;
        entry.stages = technique.stages;

        auto bindings = createLayoutBinding(technique.stages);

        entry.setLayout = device.createDescriptorSetLayout(bindings);
        entry.pipelineLayout = createPipelineLayout(
            device,
            [entry.setLayout],
            pushConstantRanges(technique.stages),
        );
        device.registerPipelineLayout(entry.pipelineLayout);

        entry.allocator = new DescriptorAllocator(device, entry.setLayout, bindings, setsPerPool);

        techniques ~= entry;

        return TechniqueId(cast(uint)(techniques.length - 1));
    }

    GraphicsPipelineCfg acquire(TechniqueId id, RenderPass renderPass, uint subpass = 0)
    {
        const key = PipelineKey(id, targetId(renderPass, subpass));

        if(auto found = key in cache)
            return *found;

        cache[key] = createPipeline(id, renderPass, subpass);

        return cache[key];
    }

    DescriptorAllocator descriptorAllocator(TechniqueId id)
    {
        assert(id.value < techniques.length);

        return techniques[id.value].allocator;
    }

    string techniqueName(TechniqueId id) const
    {
        assert(id.value < techniques.length);

        return techniques[id.value].description.name;
    }

    private RenderTargetId targetId(RenderPass renderPass, uint subpass)
    {
        foreach(i, ref target; targets)
            if(target.renderPass == renderPass.vkRenderPass && target.subpass == subpass)
                return RenderTargetId(cast(uint) i);

        targets ~= RenderTarget(renderPass.vkRenderPass, subpass);

        return RenderTargetId(cast(uint)(targets.length - 1));
    }

    private GraphicsPipelineCfg createPipeline(TechniqueId id, RenderPass renderPass, uint subpass)
    {
        import pukan.vulkan.defaults: multisampling;

        ref technique = techniques[id.value];
        const state = technique.description.state;

        VkPipelineShaderStageCreateInfo[] stages;
        foreach(ref stage; technique.stages)
            stages ~= stage.createShaderStageInfo;

        VkDynamicState[] dynamicStates = [
            VK_DYNAMIC_STATE_VIEWPORT,
            VK_DYNAMIC_STATE_SCISSOR,
        ];
        dynamicStates ~= technique.description.dynamicStates;

        VkPipelineDynamicStateCreateInfo dynamicStateInfo = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            dynamicStateCount: cast(uint) dynamicStates.length,
            pDynamicStates: dynamicStates.ptr,
        };

        VkPipelineVertexInputStateCreateInfo vertexInputInfo = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            vertexBindingDescriptionCount: cast(uint) technique.description.vertexBindings.length,
            pVertexBindingDescriptions: technique.description.vertexBindings.ptr,
            vertexAttributeDescriptionCount: cast(uint) technique.description.vertexAttributes.length,
            pVertexAttributeDescriptions: technique.description.vertexAttributes.ptr,
        };

        VkPipelineViewportStateCreateInfo viewportState = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            viewportCount: 1,
            scissorCount: 1,
        };

        VkPipelineInputAssemblyStateCreateInfo inputAssembly = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            topology: state.topology,
            primitiveRestartEnable: VK_FALSE,
        };

        VkPipelineRasterizationStateCreateInfo rasterizerInfo = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            depthClampEnable: VK_FALSE,
            rasterizerDiscardEnable: VK_FALSE,
            polygonMode: VK_POLYGON_MODE_FILL,
            cullMode: state.cullMode,
            frontFace: state.frontFace,
            depthBiasEnable: VK_FALSE,
            depthBiasConstantFactor: 0.0f,
            depthBiasClamp: 0.0f,
            depthBiasSlopeFactor: 0.0f,
            lineWidth: 1.0f,
        };

        VkPipelineDepthStencilStateCreateInfo depthStencil = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            depthTestEnable: state.depthTestEnable,
            depthWriteEnable: state.depthWriteEnable,
            depthCompareOp: state.depthCompareOp,
            depthBoundsTestEnable: VK_FALSE,
            stencilTestEnable: VK_FALSE,
        };

        VkPipelineColorBlendAttachmentState colorBlendAttachment = {
            blendEnable: state.blendEnable,
            srcColorBlendFactor: VK_BLEND_FACTOR_ONE,
            dstColorBlendFactor: VK_BLEND_FACTOR_ZERO,
            colorBlendOp: VK_BLEND_OP_ADD,
            srcAlphaBlendFactor: VK_BLEND_FACTOR_ONE,
            dstAlphaBlendFactor: VK_BLEND_FACTOR_ZERO,
            alphaBlendOp: VK_BLEND_OP_ADD,
            colorWriteMask: VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
        };

        VkPipelineColorBlendStateCreateInfo colorBlending = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            logicOpEnable: VK_FALSE,
            logicOp: VK_LOGIC_OP_COPY,
            attachmentCount: 1,
            pAttachments: &colorBlendAttachment,
            blendConstants: [0.0f, 0.0f, 0.0f, 0.0f],
        };

        VkGraphicsPipelineCreateInfo pipelineCreateInfo = {
            sType: VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            stageCount: cast(uint) stages.length,
            pStages: stages.ptr,
            pVertexInputState: &vertexInputInfo,
            pInputAssemblyState: &inputAssembly,
            pViewportState: &viewportState,
            pRasterizationState: &rasterizerInfo,
            pMultisampleState: &multisampling,
            pDepthStencilState: &depthStencil,
            pColorBlendState: &colorBlending,
            pDynamicState: &dynamicStateInfo,
            layout: technique.pipelineLayout,
            renderPass: renderPass.vkRenderPass,
            subpass: subpass,
            basePipelineHandle: null,
            basePipelineIndex: -1,
        };

        return GraphicsPipelineCfg(
            graphicsPipeline: device.createGraphicsPipelines([pipelineCreateInfo])[0],
            pipelineLayout: technique.pipelineLayout,
        );
    }

    private static VkPushConstantRange[] pushConstantRanges(ShaderInfo[] stages)
    {
        VkPushConstantRange[] ranges;

        foreach(ref stage; stages)
        {
            if(!stage.pushConstantRange.stageFlags)
                continue;

            bool found;
            foreach(ref range; ranges)
                if(range == stage.pushConstantRange)
                {
                    found = true;
                    break;
                }

            if(!found)
                ranges ~= stage.pushConstantRange;
        }

        return ranges;
    }
}
