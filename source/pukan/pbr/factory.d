module pukan.pbr.factory;

import dlib.math: Matrix4x4f, Vector2f, Vector3f, Vector4f;
import material_bindings;
import pukan.pbr.pipelines: PbrPipelineVariants, PbrPipelines;
import pukan.pbr.mesh: staticInstanceBinding;
import pukan.mesh: MeshResources;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.pipelines: DescriptorAllocator, GraphicsPipelineCfg, PipelineFactory, RenderTechnique, TechniqueId;

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
            VkVertexInputBindingDescription(
                binding: staticInstanceBinding,
                stride: Matrix4x4f.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_INSTANCE,
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
            VkVertexInputAttributeDescription(
                binding: 5,
                location: 7,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: 0,
            ),
            VkVertexInputAttributeDescription(
                binding: 5,
                location: 8,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: 4 * float.sizeof,
            ),
            VkVertexInputAttributeDescription(
                binding: 5,
                location: 9,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: 8 * float.sizeof,
            ),
            VkVertexInputAttributeDescription(
                binding: 5,
                location: 10,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: 12 * float.sizeof,
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
        samplerBinding(MATERIAL_GODOT_METALLIC),
        samplerBinding(MATERIAL_GODOT_ROUGHNESS),
    ];
}

class PbrFactory
{
    LogicalDevice device;
    private PipelineFactory pipelines;
    private TechniqueId technique;
    MeshResources resources;
    PbrPipelines pipelineCfgs;
    PbrPipelines godotPipelines;

    this(
        LogicalDevice device,
        PipelineFactory pipelines,
        MeshResources resources,
        RenderPass renderPass,
        RenderPass shadowPass,
    )
    {
        this.device = device;
        this.pipelines = pipelines;
        this.resources = resources;

        auto skinnedPbr = shaderStages!"mesh_pbr_frag.spv"(device);
        auto staticPbr = staticShaderStages!"mesh_pbr_frag.spv"(device);

        // A descriptor allocator needs a technique, but none of its pipelines.
        technique = pipelines.declare(RenderTechnique(
            name: "PBR descriptor layout",
            stages: skinnedPbr,
        ), 20);

        pipelineCfgs.skinned.pbr.ibl = createVariants("PBR", skinnedPbr, shaderStages!"mesh_pbr_frag_oit.spv"(device), renderPass);
        pipelineCfgs.skinned.pbr.analytic = createVariants("PBR analytic sky", shaderStages!"mesh_pbr_frag_analytic.spv"(device), shaderStages!"mesh_pbr_frag_oit_analytic.spv"(device), renderPass);
        pipelineCfgs.skinned.pbr.none = createVariants("PBR no sky", shaderStages!"mesh_pbr_frag_nosky.spv"(device), shaderStages!"mesh_pbr_frag_oit_nosky.spv"(device), renderPass);
        pipelineCfgs.skinned.pbrCore.ibl = createVariants("PBR core", shaderStages!"mesh_pbr_frag_core.spv"(device), shaderStages!"mesh_pbr_frag_core_oit.spv"(device), renderPass);
        pipelineCfgs.skinned.pbrCore.analytic = createVariants("PBR core analytic sky", shaderStages!"mesh_pbr_frag_core_analytic.spv"(device), shaderStages!"mesh_pbr_frag_core_oit_analytic.spv"(device), renderPass);
        pipelineCfgs.skinned.pbrCore.none = createVariants("PBR core no sky", shaderStages!"mesh_pbr_frag_core_nosky.spv"(device), shaderStages!"mesh_pbr_frag_core_oit_nosky.spv"(device), renderPass);
        pipelineCfgs.skinned.lit = createVariants("PBR lit", shaderStages!"mesh_pbr_frag_lit.spv"(device), shaderStages!"mesh_pbr_frag_lit_oit.spv"(device), renderPass);
        pipelineCfgs.skinned.unlit = createVariants("PBR unlit", shaderStages!"mesh_pbr_frag_unlit.spv"(device), shaderStages!"mesh_pbr_frag_unlit_oit.spv"(device), renderPass);

        pipelineCfgs.unskinned.pbr.ibl = createVariants("PBR static", staticPbr, staticShaderStages!"mesh_pbr_frag_oit.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbr.analytic = createVariants("PBR static analytic sky", staticShaderStages!"mesh_pbr_frag_analytic.spv"(device), staticShaderStages!"mesh_pbr_frag_oit_analytic.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbr.none = createVariants("PBR static no sky", staticShaderStages!"mesh_pbr_frag_nosky.spv"(device), staticShaderStages!"mesh_pbr_frag_oit_nosky.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbrCore.ibl = createVariants("PBR static core", staticShaderStages!"mesh_pbr_frag_core.spv"(device), staticShaderStages!"mesh_pbr_frag_core_oit.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbrCore.analytic = createVariants("PBR static core analytic sky", staticShaderStages!"mesh_pbr_frag_core_analytic.spv"(device), staticShaderStages!"mesh_pbr_frag_core_oit_analytic.spv"(device), renderPass);
        pipelineCfgs.unskinned.pbrCore.none = createVariants("PBR static core no sky", staticShaderStages!"mesh_pbr_frag_core_nosky.spv"(device), staticShaderStages!"mesh_pbr_frag_core_oit_nosky.spv"(device), renderPass);
        pipelineCfgs.unskinned.lit = createVariants("PBR static lit", staticShaderStages!"mesh_pbr_frag_lit.spv"(device), staticShaderStages!"mesh_pbr_frag_lit_oit.spv"(device), renderPass);
        pipelineCfgs.unskinned.unlit = createVariants("PBR static unlit", staticShaderStages!"mesh_pbr_frag_unlit.spv"(device), staticShaderStages!"mesh_pbr_frag_unlit_oit.spv"(device), renderPass);

        auto skinnedPbrGodot = shaderStages!"mesh_pbr_frag_godot.spv"(device);
        auto staticPbrGodot = staticShaderStages!"mesh_pbr_frag_godot.spv"(device);

        godotPipelines.skinned.pbr.ibl = createVariants("Godot", skinnedPbrGodot, shaderStages!"mesh_pbr_frag_oit_godot.spv"(device), renderPass);
        godotPipelines.skinned.pbr.analytic = createVariants("Godot analytic sky", shaderStages!"mesh_pbr_frag_analytic_godot.spv"(device), shaderStages!"mesh_pbr_frag_oit_analytic_godot.spv"(device), renderPass);
        godotPipelines.skinned.pbr.none = createVariants("Godot no sky", shaderStages!"mesh_pbr_frag_nosky_godot.spv"(device), shaderStages!"mesh_pbr_frag_oit_nosky_godot.spv"(device), renderPass);
        godotPipelines.skinned.pbrCore.ibl = createVariants("Godot core", shaderStages!"mesh_pbr_frag_core_godot.spv"(device), shaderStages!"mesh_pbr_frag_core_oit_godot.spv"(device), renderPass);
        godotPipelines.skinned.pbrCore.analytic = createVariants("Godot core analytic sky", shaderStages!"mesh_pbr_frag_core_analytic_godot.spv"(device), shaderStages!"mesh_pbr_frag_core_oit_analytic_godot.spv"(device), renderPass);
        godotPipelines.skinned.pbrCore.none = createVariants("Godot core no sky", shaderStages!"mesh_pbr_frag_core_nosky_godot.spv"(device), shaderStages!"mesh_pbr_frag_core_oit_nosky_godot.spv"(device), renderPass);
        godotPipelines.skinned.lit = createVariants("Godot lit", shaderStages!"mesh_pbr_frag_lit_godot.spv"(device), shaderStages!"mesh_pbr_frag_lit_oit_godot.spv"(device), renderPass);
        godotPipelines.skinned.unlit = createVariants("Godot unlit", shaderStages!"mesh_pbr_frag_unlit_godot.spv"(device), shaderStages!"mesh_pbr_frag_unlit_oit_godot.spv"(device), renderPass);

        godotPipelines.unskinned.pbr.ibl = createVariants("Godot static", staticPbrGodot, staticShaderStages!"mesh_pbr_frag_oit_godot.spv"(device), renderPass);
        godotPipelines.unskinned.pbr.analytic = createVariants("Godot static analytic sky", staticShaderStages!"mesh_pbr_frag_analytic_godot.spv"(device), staticShaderStages!"mesh_pbr_frag_oit_analytic_godot.spv"(device), renderPass);
        godotPipelines.unskinned.pbr.none = createVariants("Godot static no sky", staticShaderStages!"mesh_pbr_frag_nosky_godot.spv"(device), staticShaderStages!"mesh_pbr_frag_oit_nosky_godot.spv"(device), renderPass);
        godotPipelines.unskinned.pbrCore.ibl = createVariants("Godot static core", staticShaderStages!"mesh_pbr_frag_core_godot.spv"(device), staticShaderStages!"mesh_pbr_frag_core_oit_godot.spv"(device), renderPass);
        godotPipelines.unskinned.pbrCore.analytic = createVariants("Godot static core analytic sky", staticShaderStages!"mesh_pbr_frag_core_analytic_godot.spv"(device), staticShaderStages!"mesh_pbr_frag_core_oit_analytic_godot.spv"(device), renderPass);
        godotPipelines.unskinned.pbrCore.none = createVariants("Godot static core no sky", staticShaderStages!"mesh_pbr_frag_core_nosky_godot.spv"(device), staticShaderStages!"mesh_pbr_frag_core_oit_nosky_godot.spv"(device), renderPass);
        godotPipelines.unskinned.lit = createVariants("Godot static lit", staticShaderStages!"mesh_pbr_frag_lit_godot.spv"(device), staticShaderStages!"mesh_pbr_frag_lit_oit_godot.spv"(device), renderPass);
        godotPipelines.unskinned.unlit = createVariants("Godot static unlit", staticShaderStages!"mesh_pbr_frag_unlit_godot.spv"(device), staticShaderStages!"mesh_pbr_frag_unlit_oit_godot.spv"(device), renderPass);

        {
            const shadowState = FixedState(
                frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
                colorAttachmentCount: 0,
                depthBiasEnable: VK_TRUE,
                depthBiasConstantFactor: 1.25f,
                depthBiasSlopeFactor: 1.75f,
            );
            // Cutouts are often two-sided cards, so both faces must cast
            FixedState maskShadowState = shadowState;
            maskShadowState.cullMode = VK_CULL_MODE_NONE;

            VkDynamicState[] dynamicStates = [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE, VK_DYNAMIC_STATE_FRONT_FACE];

            const skinnedShadow = pipelines.declare(RenderTechnique(
                name: "PBR shadow",
                stages: shadowShaderStages!"mesh_shadow_frag.spv"(device),
                state: shadowState,
                dynamicStates: dynamicStates,
            ), 20);
            const unskinnedShadow = pipelines.declare(RenderTechnique(
                name: "PBR static shadow",
                stages: staticShadowShaderStages!"mesh_shadow_frag.spv"(device),
                state: shadowState,
                dynamicStates: dynamicStates,
            ), 20);
            const skinnedMaskShadow = pipelines.declare(RenderTechnique(
                name: "PBR mask shadow",
                stages: shadowShaderStages!"mesh_shadow_mask_frag.spv"(device),
                state: maskShadowState,
                dynamicStates: dynamicStates,
            ), 20);
            const unskinnedMaskShadow = pipelines.declare(RenderTechnique(
                name: "PBR static mask shadow",
                stages: staticShadowShaderStages!"mesh_shadow_mask_frag.spv"(device),
                state: maskShadowState,
                dynamicStates: dynamicStates,
            ), 20);
            const godotSkinnedMaskShadow = pipelines.declare(RenderTechnique(
                name: "Godot mask shadow",
                stages: shadowShaderStages!"mesh_shadow_mask_frag_godot.spv"(device),
                state: maskShadowState,
                dynamicStates: dynamicStates,
            ), 20);
            const godotUnskinnedMaskShadow = pipelines.declare(RenderTechnique(
                name: "Godot static mask shadow",
                stages: staticShadowShaderStages!"mesh_shadow_mask_frag_godot.spv"(device),
                state: maskShadowState,
                dynamicStates: dynamicStates,
            ), 20);

            pipelineCfgs.skinnedShadow = pipelines.acquire(skinnedShadow, shadowPass, 0);
            pipelineCfgs.unskinnedShadow = pipelines.acquire(unskinnedShadow, shadowPass, 0);
            pipelineCfgs.skinnedMaskShadow = pipelines.acquire(skinnedMaskShadow, shadowPass, 0);
            pipelineCfgs.unskinnedMaskShadow = pipelines.acquire(unskinnedMaskShadow, shadowPass, 0);

            godotPipelines.skinnedShadow = pipelineCfgs.skinnedShadow;
            godotPipelines.unskinnedShadow = pipelineCfgs.unskinnedShadow;
            godotPipelines.skinnedMaskShadow = pipelines.acquire(godotSkinnedMaskShadow, shadowPass, 0);
            godotPipelines.unskinnedMaskShadow = pipelines.acquire(godotUnskinnedMaskShadow, shadowPass, 0);
        }
    }

    private static ShaderInfo[] shadowShaderStages(string fragmentSpv)(LogicalDevice device)
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
            fragmentStage!fragmentSpv(device),
        ];
    }

    private static ShaderInfo[] staticShadowShaderStages(string fragmentSpv)(LogicalDevice device)
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
                vertexInput: staticVertexInput(),
            ),
            fragmentStage!fragmentSpv(device),
        ];
    }

    private PbrPipelineVariants createVariants(string prefix, ShaderInfo[] stages, ShaderInfo[] oitStages, RenderPass renderPass)
    {
        VkDynamicState[] dynamicStates = [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE, VK_DYNAMIC_STATE_FRONT_FACE];

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
                vertexInput: staticVertexInput(),
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

}
