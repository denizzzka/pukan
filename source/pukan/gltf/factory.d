module pukan.gltf.factory;

import dlib.math: Matrix4x4f, Vector2f, Vector3f, Vector4f;
import material_bindings;
import pukan.gltf;
import pukan.gltf.loader: GltfLoadOptions;
import pukan.pbr.pipelines: PbrPipelineVariants, PbrPipelines;
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
            VkVertexInputBindingDescription(
                binding: 6,
                stride: 4,
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
            VkVertexInputAttributeDescription(
                binding: 6,
                location: 6,
                format: VK_FORMAT_R8G8B8A8_UNORM,
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
            VkVertexInputBindingDescription(
                binding: 4,
                stride: 4,
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
            VkVertexInputAttributeDescription(
                binding: 4,
                location: 6,
                format: VK_FORMAT_R8G8B8A8_UNORM,
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
        Requirement!(VkPhysicalDeviceFeatures.fragmentStoresAndAtomics),
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
    PbrPipelines pipelineCfgs;
    GltfLoadOptions loadOptions;

    this(
        LogicalDevice device,
        PipelineFactory pipelines,
        MeshResources resources,
        RenderPass renderPass,
        RenderPass shadowPass,
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

        pipelineCfgs.skinned.pbr.ibl = createVariants("glTF", skinnedPbr, shaderStages!"mesh_pbr_frag_oit.spv"(device), renderPass);
        pipelineCfgs.skinned.pbr.analytic = createVariants("glTF analytic sky", shaderStages!"mesh_pbr_frag_analytic.spv"(device), shaderStages!"mesh_pbr_frag_oit_analytic.spv"(device), renderPass);
        pipelineCfgs.skinned.pbr.none = createVariants("glTF no sky", shaderStages!"mesh_pbr_frag_nosky.spv"(device), shaderStages!"mesh_pbr_frag_oit_nosky.spv"(device), renderPass);
        pipelineCfgs.skinned.pbrCore.ibl = createVariants("glTF core", shaderStages!"mesh_pbr_frag_core.spv"(device), shaderStages!"mesh_pbr_frag_core_oit.spv"(device), renderPass);
        pipelineCfgs.skinned.pbrCore.analytic = createVariants("glTF core analytic sky", shaderStages!"mesh_pbr_frag_core_analytic.spv"(device), shaderStages!"mesh_pbr_frag_core_oit_analytic.spv"(device), renderPass);
        pipelineCfgs.skinned.pbrCore.none = createVariants("glTF core no sky", shaderStages!"mesh_pbr_frag_core_nosky.spv"(device), shaderStages!"mesh_pbr_frag_core_oit_nosky.spv"(device), renderPass);
        pipelineCfgs.skinned.lit = createVariants("glTF lit", shaderStages!"mesh_pbr_frag_lit.spv"(device), shaderStages!"mesh_pbr_frag_lit_oit.spv"(device), renderPass);
        pipelineCfgs.skinned.unlit = createVariants("glTF unlit", shaderStages!"mesh_pbr_frag_unlit.spv"(device), shaderStages!"mesh_pbr_frag_unlit_oit.spv"(device), renderPass);

        pipelineCfgs.unskinned.pbr.ibl = createVariants("glTF static", staticPbr, staticShaderStages!"mesh_pbr_frag_oit.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbr.analytic = createVariants("glTF static analytic sky", staticShaderStages!"mesh_pbr_frag_analytic.spv"(device), staticShaderStages!"mesh_pbr_frag_oit_analytic.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbr.none = createVariants("glTF static no sky", staticShaderStages!"mesh_pbr_frag_nosky.spv"(device), staticShaderStages!"mesh_pbr_frag_oit_nosky.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbrCore.ibl = createVariants("glTF static core", staticShaderStages!"mesh_pbr_frag_core.spv"(device), staticShaderStages!"mesh_pbr_frag_core_oit.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbrCore.analytic = createVariants("glTF static core analytic sky", staticShaderStages!"mesh_pbr_frag_core_analytic.spv"(device), staticShaderStages!"mesh_pbr_frag_core_oit_analytic.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbrCore.none = createVariants("glTF static core no sky", staticShaderStages!"mesh_pbr_frag_core_nosky.spv"(device), staticShaderStages!"mesh_pbr_frag_core_oit_nosky.spv"(device), renderPass);
        pipelineCfgs.unskinned.lit = createVariants("glTF static lit", staticShaderStages!"mesh_pbr_frag_lit.spv"(device), staticShaderStages!"mesh_pbr_frag_lit_oit.spv"(device), renderPass);
        pipelineCfgs.unskinned.unlit = createVariants("glTF static unlit", staticShaderStages!"mesh_pbr_frag_unlit.spv"(device), staticShaderStages!"mesh_pbr_frag_unlit_oit.spv"(device), renderPass);

        {
            const shadowState = FixedState(
                frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
                colorAttachmentCount: 0,
                depthBiasEnable: VK_TRUE,
                depthBiasConstantFactor: 1.25f,
                depthBiasSlopeFactor: 1.75f,
            );

            VkDynamicState[] dynamicStates = [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE];

            const skinnedShadow = pipelines.declare(RenderTechnique(
                name: "glTF shadow",
                stages: shadowShaderStages(device),
                state: shadowState,
                dynamicStates: dynamicStates,
            ), 20);
            const unskinnedShadow = pipelines.declare(RenderTechnique(
                name: "glTF static shadow",
                stages: staticShadowShaderStages(device),
                state: shadowState,
                dynamicStates: dynamicStates,
            ), 20);

            pipelineCfgs.skinnedShadow = pipelines.acquire(skinnedShadow, shadowPass, 0);
            pipelineCfgs.unskinnedShadow = pipelines.acquire(unskinnedShadow, shadowPass, 0);
        }
    }

    private static ShaderInfo[] shadowShaderStages(LogicalDevice device)
    {
        return [
            device.uploadShaderToGPU(
                cast(ubyte[]) import("mesh_pbr_shadow_vert.spv"),
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
            fragmentStage!"mesh_shadow_frag.spv"(device),
        ];
    }

    private static ShaderInfo[] staticShadowShaderStages(LogicalDevice device)
    {
        return [
            device.uploadShaderToGPU(
                cast(ubyte[]) import("mesh_pbr_static_shadow_vert.spv"),
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
            fragmentStage!"mesh_shadow_frag.spv"(device),
        ];
    }

    private PbrPipelineVariants createVariants(string prefix, ShaderInfo[] stages, ShaderInfo[] oitStages, RenderPass renderPass)
    {
        VkDynamicState[] dynamicStates = [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE];

        TechniqueId declare(string suffix, ShaderInfo[] techniqueStages, FixedState state)
        {
            return pipelines.declare(RenderTechnique(
                name: prefix ~ suffix,
                stages: techniqueStages,
                state: state,
                dynamicStates: dynamicStates,
            ), 20);
        }

        const opaque = declare("", stages, FixedState(
            frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
            alphaToCoverage: VK_TRUE,
        ));
        const doubleSided = declare(" double sided", stages, FixedState(
            frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
            cullMode: VK_CULL_MODE_NONE,
            alphaToCoverage: VK_TRUE,
        ));
        const blend = declare(" blend", stages, FixedState(
            frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
            blendEnable: VK_TRUE,
            depthWriteEnable: VK_FALSE,
        ));
        const doubleSidedBlend = declare(" double sided blend", stages, FixedState(
            frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
            cullMode: VK_CULL_MODE_NONE,
            blendEnable: VK_TRUE,
            depthWriteEnable: VK_FALSE,
        ));
        const oit = declare(" oit", oitStages, FixedState(
            frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
            depthWriteEnable: VK_FALSE,
            colorWriteMask: 0,
        ));
        const doubleSidedOit = declare(" double sided oit", oitStages, FixedState(
            frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
            cullMode: VK_CULL_MODE_NONE,
            depthWriteEnable: VK_FALSE,
            colorWriteMask: 0,
        ));

        PbrPipelineVariants result;
        result.opaque = pipelines.acquire(opaque, renderPass, 1);
        result.doubleSided = pipelines.acquire(doubleSided, renderPass, 1);
        result.blend = pipelines.acquire(blend, renderPass, 1);
        result.doubleSidedBlend = pipelines.acquire(doubleSidedBlend, renderPass, 1);
        result.oit = pipelines.acquire(oit, renderPass, 1);
        result.doubleSidedOit = pipelines.acquire(doubleSidedOit, renderPass, 1);

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

    /// A private allocator, so loads can run on different threads.
    DescriptorAllocator createAllocator()
    {
        return pipelines.createDescriptorAllocator(technique);
    }

    auto create(string filename)
    {
        assert(device);

        auto allocator = createAllocator();

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
