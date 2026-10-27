module pukan.vulkan.pipelines;

import pukan.exceptions: PukanException;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;

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
        VkPipelineLayout pipelineLayout;
        DescriptorAllocator allocator;
    }

    private struct RenderTarget
    {
        VkRenderPass renderPass;
        uint subpass;
    }

    private struct PipelineLayoutEntry
    {
        VkDescriptorSetLayout setLayout;
        VkPushConstantRange[] pushConstants;
        VkPipelineLayout layout;
    }

    private LogicalDevice device;
    private Technique[] techniques;
    private RenderTarget[] targets;
    private GraphicsPipelineCfg[PipelineKey] cache;

    private VkDescriptorSetLayout[] setLayouts;
    private VkDescriptorSetLayoutBinding[][] setLayoutBindings;
    private PipelineLayoutEntry[] pipelineLayoutEntries;

    this(LogicalDevice device)
    {
        this.device = device;
    }

    TechniqueId declare(RenderTechnique technique, uint setsPerPool = 16)
    {
        Technique entry;
        entry.description = technique;

        auto bindings = createLayoutBinding(technique.stages);
        auto setLayout = internSetLayout(bindings);

        entry.pipelineLayout = internPipelineLayout(setLayout, pushConstantRanges(technique.stages));

        entry.allocator = new DescriptorAllocator(device, setLayout, bindings, setsPerPool);

        techniques ~= entry;

        return TechniqueId(cast(uint)(techniques.length - 1));
    }

    GraphicsPipelineCfg acquire(TechniqueId id, RenderPass renderPass, uint subpass = 0)
    {
        const key = PipelineKey(id, targetId(renderPass, subpass));

        if(auto found = key in cache)
            return *found;

        try
            cache[key] = createPipeline(id, renderPass, subpass);
        catch(PukanException e)
        {
            e.msg = "technique " ~ techniqueName(id) ~ ": " ~ e.msg;
            throw e;
        }

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

    private VkDescriptorSetLayout internSetLayout(VkDescriptorSetLayoutBinding[] bindings)
    {
        foreach(i, ref existing; setLayoutBindings)
            if(existing == bindings)
                return setLayouts[i];

        auto layout = device.createDescriptorSetLayout(bindings);

        setLayouts ~= layout;
        setLayoutBindings ~= bindings.dup;

        return layout;
    }

    private VkPipelineLayout internPipelineLayout(
        VkDescriptorSetLayout setLayout,
        VkPushConstantRange[] pushConstants,
    )
    {
        foreach(ref entry; pipelineLayoutEntries)
            if(entry.setLayout == setLayout && entry.pushConstants == pushConstants)
                return entry.layout;

        auto layout = createPipelineLayout(device, [setLayout], pushConstants);
        device.registerPipelineLayout(layout);

        pipelineLayoutEntries ~= PipelineLayoutEntry(setLayout, pushConstants.dup, layout);

        return layout;
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
        foreach(ref stage; technique.description.stages)
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
