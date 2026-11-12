module pukan.graphics.g3d.section;

import dlib.math: Vector4f;
import pukan.graphics.common.shaders: shaderStage;
import pukan.graphics.g3d.custom_pass: CustomPass, DrawSubject, PipelineOverride, passDataOffset, pushConstantBytes;
import pukan.graphics.g3d.material: AlphaMode;
import pukan.graphics.g3d.pbr.pipeline_set: shaderStages, staticShaderStages;
import pukan.graphics.g3d.pbr.pipelines: LazyPipeline, PbrProfile;
import pukan.vulkan.bindings;
import pukan.vulkan.pipelines: FixedState, PipelineFactory, RenderTechnique;
import pukan.vulkan.renderpass: DrawPhase, RenderPass;
import pukan.vulkan.shaders: ShaderDecl;

/// Push constant block of the section shaders
struct SectionData
{
    /// plane: xyz = normal, w = -dot(point, normal); sphere and capsule: xyz = centre, w = radius
    Vector4f shape;
    /// x = plane NDC depth, y = fill (0 hatch, 1 colour), z = shape
    Vector4f params;
}

static assert(SectionData.sizeof == 32);

/// Cuts the opaque PBR scene with a camera-facing shape and fills the cut.
/// The core knows nothing about it: the pass brings its phases, pipelines and
/// data, and an off pass records no draw at all.
final class SectionPass : CustomPass
{
    bool enabled;
    /// Cut shape in world space
    Vector4f shape = Vector4f(0, 0, 1, 0);
    /// NDC depth of the cap a plane cut leaves
    float ndcZ;
    /// 0 hatches the cap, 1 fills it with a solid colour
    float fill;
    /// 0 plane, 1 sphere, 2 capsule from the camera
    uint mode;

    private LazyPipeline unskinnedOpaque;
    private LazyPipeline unskinnedDoubleSided;
    private LazyPipeline skinnedOpaque;
    private LazyPipeline skinnedDoubleSided;
    private LazyPipeline unskinnedStencil;
    private LazyPipeline skinnedStencil;
    private LazyPipeline cap;
    private SectionData data;

    this(PipelineFactory factory, RenderPass pass)
    {
        VkDynamicState[] dynamicStates = [VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE, VK_DYNAMIC_STATE_FRONT_FACE];

        const fragmentPush = VkPushConstantRange(
            stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            offset: passDataOffset,
            size: SectionData.sizeof,
        );

        auto skinnedSection = shaderStages!"mesh_pbr_frag_section.spv"(fragmentPush);
        auto staticSection = staticShaderStages!"mesh_pbr_frag_section.spv"(fragmentPush);
        auto skinnedStencilStages = shaderStages!"mesh_section_stencil_frag.spv"(fragmentPush);
        auto staticStencilStages = staticShaderStages!"mesh_section_stencil_frag.spv"(fragmentPush);

        const sectionState = FixedState(
            frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
            alphaToCoverage: VK_TRUE,
        );

        FixedState sectionDoubleSidedState = sectionState;
        sectionDoubleSidedState.cullMode = VK_CULL_MODE_NONE;

        const stencilState = FixedState(
            cullMode: VK_CULL_MODE_NONE,
            frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE,
            depthTestEnable: VK_TRUE,
            depthWriteEnable: VK_FALSE,
            depthCompareOp: VK_COMPARE_OP_GREATER_OR_EQUAL,
            colorWriteMask: 0,
            stencilTestEnable: VK_TRUE,
            frontStencil: VkStencilOpState(
                failOp: VK_STENCIL_OP_KEEP,
                passOp: VK_STENCIL_OP_INCREMENT_AND_WRAP,
                depthFailOp: VK_STENCIL_OP_KEEP,
                compareOp: VK_COMPARE_OP_ALWAYS,
                compareMask: 0xFF,
                writeMask: 0xFF,
                reference: 0,
            ),
            backStencil: VkStencilOpState(
                failOp: VK_STENCIL_OP_KEEP,
                passOp: VK_STENCIL_OP_DECREMENT_AND_WRAP,
                depthFailOp: VK_STENCIL_OP_KEEP,
                compareOp: VK_COMPARE_OP_ALWAYS,
                compareMask: 0xFF,
                writeMask: 0xFF,
                reference: 0,
            ),
        );

        LazyPipeline declare(string suffix, ShaderDecl[] stages, FixedState state)
        {
            return LazyPipeline(factory, factory.declare(RenderTechnique(
                name: "section " ~ suffix,
                stages: stages,
                state: state,
                dynamicStates: dynamicStates,
            ), 20), pass, 1);
        }

        unskinnedOpaque = declare("static", staticSection, sectionState);
        unskinnedDoubleSided = declare("static double sided", staticSection, sectionDoubleSidedState);
        skinnedOpaque = declare("skinned", skinnedSection, sectionState);
        skinnedDoubleSided = declare("skinned double sided", skinnedSection, sectionDoubleSidedState);

        unskinnedStencil = declare("static stencil", staticStencilStages, stencilState);
        skinnedStencil = declare("skinned stencil", skinnedStencilStages, stencilState);

        const capPush = VkPushConstantRange(
            stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            offset: 0,
            size: SectionData.sizeof,
        );

        auto capVertex = shaderStage!"section_cap_vert.spv"(VK_SHADER_STAGE_VERTEX_BIT, null);
        auto capFragment = shaderStage!"section_cap_frag.spv"(VK_SHADER_STAGE_FRAGMENT_BIT, null, capPush);

        const capStencil = VkStencilOpState(
            failOp: VK_STENCIL_OP_KEEP,
            passOp: VK_STENCIL_OP_KEEP,
            depthFailOp: VK_STENCIL_OP_KEEP,
            compareOp: VK_COMPARE_OP_NOT_EQUAL,
            compareMask: 0xFF,
            writeMask: 0,
            reference: 0,
        );

        cap = LazyPipeline(factory, factory.declare(RenderTechnique(
            name: "section cap",
            stages: [capVertex, capFragment],
            state: FixedState(
                cullMode: VK_CULL_MODE_NONE,
                depthTestEnable: VK_TRUE,
                depthWriteEnable: VK_TRUE,
                depthCompareOp: VK_COMPARE_OP_GREATER_OR_EQUAL,
                stencilTestEnable: VK_TRUE,
                frontStencil: capStencil,
                backStencil: capStencil,
            ),
        )), pass, 1);
    }

    override bool active() const => enabled;

    override bool drawsCustomPhase() const => true;

    override bool claims(in DrawSubject subject)
    {
        return enabled && subject.profile == PbrProfile.gltf
            && subject.opaque && subject.pbr
            && subject.alphaMode == AlphaMode.opaque;
    }

    override PipelineOverride overridePipeline(in DrawSubject subject)
    {
        if(!claims(subject))
            return PipelineOverride.init;

        LazyPipeline* pipeline;

        if(subject.phase == DrawPhase.custom)
            pipeline = subject.skinned ? &skinnedStencil : &unskinnedStencil;
        else if(subject.phase == DrawPhase.surface)
        {
            if(subject.skinned)
                pipeline = subject.doubleSided ? &skinnedDoubleSided : &skinnedOpaque;
            else
                pipeline = subject.doubleSided ? &unskinnedDoubleSided : &unskinnedOpaque;
        }
        else
            return PipelineOverride.init;

        return PipelineOverride(pipeline, updateData());
    }

    /// Clears the stencil the count writes; the ordinary depth stays untouched
    override void begin(VkCommandBuffer cmd, VkDescriptorSet frameSet, VkExtent2D extent)
    {
        VkClearAttachment attachment = {
            aspectMask: VK_IMAGE_ASPECT_STENCIL_BIT,
            colorAttachment: 0,
            clearValue: VkClearValue(depthStencil: VkClearDepthStencilValue(0, 0)),
        };

        VkClearRect rect = {
            rect: VkRect2D(offset: VkOffset2D(0, 0), extent: extent),
            baseArrayLayer: 0,
            layerCount: 1,
        };

        vkCmdClearAttachments(cmd, 1, &attachment, 1, &rect);
    }

    /// Fills the cut with the hatch or the solid colour
    override void end(VkCommandBuffer cmd, VkDescriptorSet frameSet)
    {
        auto cfg = cap.get("section cap");
        const bytes = updateData();

        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, cfg.graphicsPipeline);
        vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, cfg.pipelineLayout,
            1, 1, &frameSet, 0, null);
        vkCmdPushConstants(cmd, cfg.pipelineLayout, VK_SHADER_STAGE_FRAGMENT_BIT,
            0, cast(uint) bytes.length, cast(void*) bytes.ptr);
        vkCmdDraw(cmd, 3, 1, 0, 0);
    }

    private const(ubyte)[] updateData()
    {
        data.shape = shape;
        data.params = Vector4f(ndcZ, fill, cast(float) mode, 0);

        return pushConstantBytes(data);
    }
}
