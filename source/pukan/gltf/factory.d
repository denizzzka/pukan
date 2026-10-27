module pukan.gltf.factory;

import dlib.math: Matrix4x4f, Vector2f, Vector3f;
import pukan.gltf;
import pukan.gltf.pipelines: GltfPipelines;
import pukan.material: MaterialBuffer;
import pukan.mesh: MeshResources;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.pipelines: DescriptorAllocator, GraphicsPipelineCfg, PipelineFactory, RenderTechnique, TechniqueId;
import std.meta: AliasSeq;

private ShaderVertexInput vertexInput()
{
    return ShaderVertexInput(
        [
            VkVertexInputBindingDescription(
                binding: 0,
                stride: Vector3f.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
            VkVertexInputBindingDescription(
                binding: 1,
                stride: Vector2f.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
            VkVertexInputBindingDescription(
                binding: 2,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
            VkVertexInputBindingDescription(
                binding: 3,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
            VkVertexInputBindingDescription(
                binding: 4,
                stride: Vector3f.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
        ],
        [
            VkVertexInputAttributeDescription(
                binding: 0,
                location: 0,
                format: VK_FORMAT_R32G32B32_SFLOAT,
            ),
            VkVertexInputAttributeDescription(
                binding: 1,
                location: 1,
                format: VK_FORMAT_R32G32_SFLOAT,
            ),
            VkVertexInputAttributeDescription(
                binding: 2,
                location: 2,
                format: VK_FORMAT_R16G16B16A16_UINT,
            ),
            VkVertexInputAttributeDescription(
                binding: 3,
                location: 3,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
            ),
            VkVertexInputAttributeDescription(
                binding: 4,
                location: 4,
                format: VK_FORMAT_R32G32B32_SFLOAT,
            ),
        ],
    );
}

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
    GltfPipelines pipelineCfgs;

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

        auto stages = shaderStages(device);
        VkDynamicState[] dynamicStates = [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE];

        technique = pipelines.declare(RenderTechnique(
            name: "glTF",
            stages: stages,
            state: FixedState(frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE),
            dynamicStates: dynamicStates,
        ), 20);

        const doubleSidedTechnique = pipelines.declare(RenderTechnique(
            name: "glTF double sided",
            stages: stages,
            state: FixedState(
                frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
                cullMode: VK_CULL_MODE_NONE,
            ),
            dynamicStates: dynamicStates,
        ), 20);

        const blendTechnique = pipelines.declare(RenderTechnique(
            name: "glTF blend",
            stages: stages,
            state: FixedState(
                frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
                blendEnable: VK_TRUE,
                depthWriteEnable: VK_FALSE,
            ),
            dynamicStates: dynamicStates,
        ), 20);

        const doubleSidedBlendTechnique = pipelines.declare(RenderTechnique(
            name: "glTF double sided blend",
            stages: stages,
            state: FixedState(
                frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
                cullMode: VK_CULL_MODE_NONE,
                blendEnable: VK_TRUE,
                depthWriteEnable: VK_FALSE,
            ),
            dynamicStates: dynamicStates,
        ), 20);

        pipelineCfgs.opaque = pipelines.acquire(technique, renderPass, 1);
        pipelineCfgs.doubleSided = pipelines.acquire(doubleSidedTechnique, renderPass, 1);
        pipelineCfgs.blend = pipelines.acquire(blendTechnique, renderPass, 1);
        pipelineCfgs.doubleSidedBlend = pipelines.acquire(doubleSidedBlendTechnique, renderPass, 1);
    }

    private static ShaderInfo[] shaderStages(LogicalDevice device)
    {
        return [
            device.uploadShaderToGPU(
                cast(ubyte[]) import("mesh_pbr_vert.spv"),
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
                vertexInput(),
            ),
            device.uploadShaderToGPU(
                cast(ubyte[]) import("mesh_pbr_frag.spv"),
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
                    VkDescriptorSetLayoutBinding(
                        binding: 3,
                        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        descriptorCount: 1,
                        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
                    ),
                    VkDescriptorSetLayoutBinding(
                        binding: 4,
                        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        descriptorCount: 1,
                        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
                    ),
                    VkDescriptorSetLayoutBinding(
                        binding: 5,
                        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                        descriptorCount: 1,
                        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
                    ),
                    VkDescriptorSetLayoutBinding(
                        binding: 6,
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
                pipelineCfgs,
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
