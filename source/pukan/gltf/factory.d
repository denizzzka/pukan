module pukan.gltf.factory;

import dlib.math: Matrix4x4f;
import pukan.gltf;
import pukan.mesh: MeshResources;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.pipelines: DescriptorAllocator, GraphicsPipelineCfg, PipelineFactory, RenderTechnique, TechniqueId;
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
    private PipelineFactory pipelines;
    private TechniqueId technique;
    private MeshResources resources;
    GraphicsPipelineCfg graphicsPipelineCfg;

    this(
        LogicalDevice device,
        PipelineFactory pipelines,
        MeshResources resources,
        RenderPass renderPass,
        bool computeJointsOnGPU = true,
    )
    {
        this.device = device;
        this.computeJointsOnGPU = computeJointsOnGPU;
        this.pipelines = pipelines;
        this.resources = resources;

        technique = pipelines.declare(RenderTechnique(
            name: "glTF",
            stages: shaderStages(device),
            vertexBindings: ShaderVertex.getBindingDescriptions,
            vertexAttributes: ShaderVertex.getAttributeDescriptions,
            state: FixedState(frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE),
            dynamicStates: [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE],
        ), 20);

        graphicsPipelineCfg = pipelines.acquire(technique, renderPass, 1);
    }

    private static ShaderInfo[] shaderStages(LogicalDevice device)
    {
        return [
            device.uploadShaderToGPU(
                cast(ubyte[]) import("mesh_skinned_vert.spv"),
                VK_SHADER_STAGE_VERTEX_BIT,
                [
                    VkDescriptorSetLayoutBinding(
                        binding: 2,
                        descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                        descriptorCount: 1,
                        stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                    ),
                ],
                VkPushConstantRange(
                    stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                    offset: 0,
                    size: Matrix4x4f.sizeof,
                ),
            ),
            device.uploadShaderToGPU(
                cast(ubyte[]) import("mesh_frag.spv"),
                VK_SHADER_STAGE_FRAGMENT_BIT,
                [
                    VkDescriptorSetLayoutBinding(
                        binding: 0,
                        descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                        descriptorCount: 1,
                        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
                    ),
                    VkDescriptorSetLayoutBinding(
                        binding: 1,
                        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        descriptorCount: 1,
                        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
                    ),
                ],
            ),
        ];
    }

    auto create(string filename)
    {
        assert(device);

        // A private allocator, so loads can run on different threads.
        auto allocator = pipelines.createDescriptorAllocator(technique);

        try
            return loadGlTF2(
                filename,
                allocator,
                resources.materials,
                device,
                graphicsPipelineCfg,
                resources.fakeTexture,
                computeJointsOnGPU,
            );
        catch(Exception e)
        {
            e.msg = filename~": "~e.msg;
            //FIXME: use correct exception type
            throw e;
        }
    }
}
