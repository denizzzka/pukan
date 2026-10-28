module pukan.gltf.factory;

import dlib.math: Matrix4x4f, Vector2f, Vector3f, Vector4f;
import material_bindings;
import pukan.gltf;
import pukan.gltf.loader: GltfLoadOptions;
import pukan.gltf.pipelines: GltfPipelineVariants, GltfPipelines;
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
            VkVertexInputBindingDescription(
                binding: 5,
                stride: Vector4f.sizeof,
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
            VkVertexInputAttributeDescription(
                binding: 5,
                location: 5,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
            ),
        ],
    );
}

private ShaderVertexInput staticVertexInput()
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
                stride: Vector3f.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
            VkVertexInputBindingDescription(
                binding: 3,
                stride: Vector4f.sizeof,
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
                format: VK_FORMAT_R32G32B32_SFLOAT,
            ),
            VkVertexInputAttributeDescription(
                binding: 3,
                location: 3,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
            ),
        ],
    );
}

//TODO: derive the bindings from the shader modules instead of this list and
// material_bindings.h, once SPIR-V reflection is in place.
private VkDescriptorSetLayoutBinding[] fragmentBindings()
{
    VkDescriptorSetLayoutBinding samplerBinding(uint binding)
    {
        return VkDescriptorSetLayoutBinding(
            binding: binding,
            descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            descriptorCount: 1,
            stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
        );
    }

    return [
        VkDescriptorSetLayoutBinding(
            binding: MATERIAL_UNIFORM,
            descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            descriptorCount: 1,
            stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
        ),
        samplerBinding(MATERIAL_BASE_COLOR),
        samplerBinding(MATERIAL_METALLIC_ROUGHNESS),
        samplerBinding(MATERIAL_NORMAL),
        samplerBinding(MATERIAL_OCCLUSION),
        samplerBinding(MATERIAL_EMISSIVE),
        samplerBinding(MATERIAL_SPECULAR),
        samplerBinding(MATERIAL_SPECULAR_COLOR),
        samplerBinding(MATERIAL_CLEARCOAT),
        samplerBinding(MATERIAL_CLEARCOAT_ROUGHNESS),
        samplerBinding(MATERIAL_CLEARCOAT_NORMAL),
        samplerBinding(MATERIAL_SHEEN_COLOR),
        samplerBinding(MATERIAL_SHEEN_ROUGHNESS),
        samplerBinding(MATERIAL_ANISOTROPY),
        samplerBinding(MATERIAL_IRIDESCENCE),
        samplerBinding(MATERIAL_IRIDESCENCE_THICKNESS),
        samplerBinding(MATERIAL_TRANSMISSION),
        samplerBinding(MATERIAL_VOLUME_THICKNESS),
    ];
}

class GltfFactory
{
    import pukan.gltf.skin_matrices: SkinMatrices;

    private alias requirements = AliasSeq!(
        SkinMatrices.requirements,
        Requirement!(VkQueueFamilyProperties.queueFlags, VK_QUEUE_GRAPHICS_BIT),
        ImageFormatRequirement!(VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL,
            VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT),
        FormatRequirement!(VK_FORMAT_R8G8B8A8_SRGB,
            VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT
            | VK_FORMAT_FEATURE_BLIT_SRC_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT),
        ImageFormatRequirement!(VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL,
            VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT),
        FormatRequirement!(VK_FORMAT_R8G8B8A8_UNORM,
            VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT
            | VK_FORMAT_FEATURE_BLIT_SRC_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT),
    );

    LogicalDevice device;
    private immutable bool computeJointsOnGPU;
    private PipelineFactory pipelines;
    private TechniqueId technique;
    private MeshResources resources;
    GltfPipelines pipelineCfgs;
    GltfLoadOptions loadOptions;

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

        auto skinnedPbr = shaderStages!"mesh_pbr_frag.spv"(device);
        auto staticPbr = staticShaderStages!"mesh_pbr_frag.spv"(device);

        // A descriptor allocator needs a technique, but none of its pipelines.
        technique = pipelines.declare(RenderTechnique(
            name: "glTF descriptor layout",
            stages: skinnedPbr,
        ), 20);

        pipelineCfgs.skinned.pbr.ibl = createVariants("glTF", skinnedPbr, renderPass);
        pipelineCfgs.skinned.pbr.analytic = createVariants("glTF analytic sky", shaderStages!"mesh_pbr_frag_analytic.spv"(device), renderPass);
        pipelineCfgs.skinned.pbr.none = createVariants("glTF no sky", shaderStages!"mesh_pbr_frag_nosky.spv"(device), renderPass);
        pipelineCfgs.skinned.pbrCore.ibl = createVariants("glTF core", shaderStages!"mesh_pbr_frag_core.spv"(device), renderPass);
        pipelineCfgs.skinned.pbrCore.analytic = createVariants("glTF core analytic sky", shaderStages!"mesh_pbr_frag_core_analytic.spv"(device), renderPass);
        pipelineCfgs.skinned.pbrCore.none = createVariants("glTF core no sky", shaderStages!"mesh_pbr_frag_core_nosky.spv"(device), renderPass);
        pipelineCfgs.skinned.lit = createVariants("glTF lit", shaderStages!"mesh_pbr_frag_lit.spv"(device), renderPass);
        pipelineCfgs.skinned.unlit = createVariants("glTF unlit", shaderStages!"mesh_pbr_frag_unlit.spv"(device), renderPass);

        pipelineCfgs.unskinned.pbr.ibl = createVariants("glTF static", staticPbr, renderPass);
        pipelineCfgs.unskinned.pbr.analytic = createVariants("glTF static analytic sky", staticShaderStages!"mesh_pbr_frag_analytic.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbr.none = createVariants("glTF static no sky", staticShaderStages!"mesh_pbr_frag_nosky.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbrCore.ibl = createVariants("glTF static core", staticShaderStages!"mesh_pbr_frag_core.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbrCore.analytic = createVariants("glTF static core analytic sky", staticShaderStages!"mesh_pbr_frag_core_analytic.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbrCore.none = createVariants("glTF static core no sky", staticShaderStages!"mesh_pbr_frag_core_nosky.spv"(device), renderPass);
        pipelineCfgs.unskinned.lit = createVariants("glTF static lit", staticShaderStages!"mesh_pbr_frag_lit.spv"(device), renderPass);
        pipelineCfgs.unskinned.unlit = createVariants("glTF static unlit", staticShaderStages!"mesh_pbr_frag_unlit.spv"(device), renderPass);
    }

    private GltfPipelineVariants createVariants(string prefix, ShaderInfo[] stages, RenderPass renderPass)
    {
        VkDynamicState[] dynamicStates = [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE];

        TechniqueId declare(string suffix, FixedState state)
        {
            return pipelines.declare(RenderTechnique(
                name: prefix ~ suffix,
                stages: stages,
                state: state,
                dynamicStates: dynamicStates,
            ), 20);
        }

        const opaque = declare("", FixedState(
            frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
            alphaToCoverage: VK_TRUE,
        ));
        const doubleSided = declare(" double sided", FixedState(
            frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
            cullMode: VK_CULL_MODE_NONE,
            alphaToCoverage: VK_TRUE,
        ));
        const blend = declare(" blend", FixedState(
            frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
            blendEnable: VK_TRUE,
            depthWriteEnable: VK_FALSE,
        ));
        const doubleSidedBlend = declare(" double sided blend", FixedState(
            frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
            cullMode: VK_CULL_MODE_NONE,
            blendEnable: VK_TRUE,
            depthWriteEnable: VK_FALSE,
        ));

        GltfPipelineVariants result;
        result.opaque = pipelines.acquire(opaque, renderPass, 1);
        result.doubleSided = pipelines.acquire(doubleSided, renderPass, 1);
        result.blend = pipelines.acquire(blend, renderPass, 1);
        result.doubleSidedBlend = pipelines.acquire(doubleSidedBlend, renderPass, 1);

        return result;
    }

    private static ShaderInfo[] shaderStages(string fragmentSpv)(LogicalDevice device)
    {
        return [
            device.uploadShaderToGPU(
                cast(ubyte[]) import("mesh_pbr_vert.spv"),
                VK_SHADER_STAGE_VERTEX_BIT,
                [
                    VkDescriptorSetLayoutBinding(
                        binding: MATERIAL_JOINTS,
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
            fragmentStage!fragmentSpv(device),
        ];
    }

    private static ShaderInfo[] staticShaderStages(string fragmentSpv)(LogicalDevice device)
    {
        return [
            device.uploadShaderToGPU(
                cast(ubyte[]) import("mesh_pbr_static_vert.spv"),
                VK_SHADER_STAGE_VERTEX_BIT,
                [
                    VkDescriptorSetLayoutBinding(
                        binding: MATERIAL_JOINTS,
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
                staticVertexInput(),
            ),
            fragmentStage!fragmentSpv(device),
        ];
    }

    private static ShaderInfo fragmentStage(string fragmentSpv)(LogicalDevice device)
    {
        return device.uploadShaderToGPU(
            cast(ubyte[]) import(fragmentSpv),
            VK_SHADER_STAGE_FRAGMENT_BIT,
            fragmentBindings(),
        );
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
                resources.fallbackVertex.buf,
                computeJointsOnGPU,
                loadOptions,
            );
        catch(Exception e)
        {
            e.msg = filename~": "~e.msg;
            //FIXME: use correct exception type
            throw e;
        }
    }
}
