module pukan.gltf.factory;

import pukan.gltf;
import pukan.vulkan;
import pukan.vulkan.bindings;
import std.meta: AliasSeq;

class PipelineInfoCreator : DefaultGraphicsPipelineInfoCreator!ShaderVertex
{
    import pukan.vulkan.bindings;
    import pukan.vulkan.renderpass;

    this(LogicalDevice dev, VkDescriptorSetLayout[] descriptorSetLayouts, ShaderInfo[] shads, RenderPass renderPass)
    {
        rasterizerInfo.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
        dynamicStates ~= VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE;

        super(dev, descriptorSetLayouts, shads, renderPass);
    }
}

class GltfFactory
{
    import pukan.vulkan;
    import shaders = pukan.vulkan.shaders;
    import pukan.vulkan.frame_builder;
    import pukan.gltf.skin_matrices: SkinMatrices;

    private alias requirements = AliasSeq!(
        SkinMatrices.requirements,
        Requirement!(VkQueueFamilyProperties.queueFlags, VK_QUEUE_GRAPHICS_BIT),
        FormatRequirement!(VK_FORMAT_R8G8B8A8_SRGB,
            VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT),
    );

    LogicalDevice device;
    private immutable bool computeJointsOnGPU;
    private PoolAndLayoutInfo poolAndLayout;
    //TODO: contains part of poolAndLayout data. Deduplicate?
    private DefaultGraphicsPipelineInfoCreator!ShaderVertex pipelineInfoCreator;
    GraphicsPipelineCfg graphicsPipelineCfg;
    private Texture fakeTexture; /// Stub to fill texture shader arg of non-textured meshes

    //TODO: remove shaderStages arg, set it implicitly
    this(LogicalDevice device, ShaderInfo[] shaderStages, RenderPass renderPass, bool computeJointsOnGPU = true)
    {
        this.device = device;
        this.computeJointsOnGPU = computeJointsOnGPU;

        auto layoutBindings = shaders.createLayoutBinding(shaderStages);
        poolAndLayout = device.createDescriptorPool(layoutBindings, 20 /*FIXME*/);

        pipelineInfoCreator = new PipelineInfoCreator(device, [poolAndLayout.descriptorSetLayout], shaderStages, renderPass);
        graphicsPipelineCfg.pipelineLayout = pipelineInfoCreator.pipelineLayout;

        auto pipelineCreateInfo = pipelineInfoCreator.pipelineCreateInfo;
        graphicsPipelineCfg.graphicsPipeline = device.createGraphicsPipelines([pipelineCreateInfo])[0];

        fakeTexture = createFakeTexture1x1(device);
    }

    auto create(string filename)
    {
        assert(device);

        try
            return loadGlTF2(filename, poolAndLayout, device, graphicsPipelineCfg, fakeTexture, computeJointsOnGPU);
        catch(Exception e)
        {
            e.msg = filename~": "~e.msg;
            //FIXME: use correct exception type
            throw e;
        }
    }
}
