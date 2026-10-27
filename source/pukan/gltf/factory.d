module pukan.gltf.factory;

import pukan.gltf;
import pukan.gltf.mesh: MaterialBuffer;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.pipelines: DescriptorAllocator, GraphicsPipelineCfg, PipelineFactory, RenderTechnique;
import std.meta: AliasSeq;

class GltfFactory
{
    import pukan.gltf.skin_matrices: SkinMatrices;

    private alias requirements = AliasSeq!(
        SkinMatrices.requirements,
        Requirement!(VkQueueFamilyProperties.queueFlags, VK_QUEUE_GRAPHICS_BIT),
        FormatRequirement!(VK_FORMAT_R8G8B8A8_SRGB,
            VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT),
    );

    LogicalDevice device;
    private immutable bool computeJointsOnGPU;
    private DescriptorAllocator allocator;
    private MaterialBuffer materialBuffer;
    GraphicsPipelineCfg graphicsPipelineCfg;
    private Texture fakeTexture; /// Stub to fill texture shader arg of non-textured meshes

    this(
        LogicalDevice device,
        PipelineFactory pipelines,
        ShaderInfo[] shaderStages,
        RenderPass renderPass,
        bool computeJointsOnGPU = true,
    )
    {
        this.device = device;
        this.computeJointsOnGPU = computeJointsOnGPU;

        const technique = pipelines.declare(RenderTechnique(
            name: "glTF",
            stages: shaderStages,
            vertexBindings: ShaderVertex.getBindingDescriptions,
            vertexAttributes: ShaderVertex.getAttributeDescriptions,
            state: FixedState(frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE),
            dynamicStates: [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE],
        ), 20);

        allocator = pipelines.descriptorAllocator(technique);
        graphicsPipelineCfg = pipelines.acquire(technique, renderPass, 1);
        materialBuffer = new MaterialBuffer(device);

        fakeTexture = createFakeTexture1x1(device);
    }

    ~this()
    {
        if(materialBuffer)
            destroy(materialBuffer);
    }

    auto create(string filename)
    {
        assert(device);

        try
            return loadGlTF2(filename, allocator, materialBuffer, device, graphicsPipelineCfg, fakeTexture, computeJointsOnGPU);
        catch(Exception e)
        {
            e.msg = filename~": "~e.msg;
            //FIXME: use correct exception type
            throw e;
        }
    }
}
