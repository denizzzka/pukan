module pukan.graphics.g3d.section;

import pukan.graphics.common.shaders: shaderStage;
import pukan.graphics.g3d.pbr.pipelines: LazyPipeline;
import pukan.vulkan.bindings;
import pukan.vulkan.pipelines: FixedState, PipelineFactory, RenderTechnique;
import pukan.vulkan.renderpass: RenderPass;

/// Stencil cap of the section cut. The cut itself lives in the section
/// pipeline variants, which only exist while the cut is on.
final class Section
{
    /// The rest of the section state, the shape and its mode, is in the scene
    bool enabled;

    private LazyPipeline cap;
    private LazyPipeline sphereDepth;

    this(PipelineFactory factory, RenderPass pass)
    {
        auto vertex = shaderStage!"section_cap_vert.spv"(
            VK_SHADER_STAGE_VERTEX_BIT,
            null,
        );
        auto fragment = shaderStage!"section_cap_frag.spv"(
            VK_SHADER_STAGE_FRAGMENT_BIT,
            null,
        );

        const VkStencilOpState capStencil = {
            failOp: VK_STENCIL_OP_KEEP,
            passOp: VK_STENCIL_OP_KEEP,
            depthFailOp: VK_STENCIL_OP_KEEP,
            compareOp: VK_COMPARE_OP_NOT_EQUAL,
            compareMask: 0xFF,
            writeMask: 0,
            reference: 0,
        };

        cap = LazyPipeline(factory, factory.declare(RenderTechnique(
            name: "section cap",
            stages: [vertex, fragment],
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

        // Writes the sphere's far surface into depth, so the stencil pass can
        // count only the solid up to that surface
        sphereDepth = LazyPipeline(factory, factory.declare(RenderTechnique(
            name: "section sphere depth",
            stages: [vertex, fragment],
            state: FixedState(
                cullMode: VK_CULL_MODE_NONE,
                depthTestEnable: VK_FALSE,
                depthWriteEnable: VK_TRUE,
                colorWriteMask: 0,
            ),
        )), pass, 1);
    }

    /// Clears the stencil the section count writes, inside the 3D subpass
    void clearStencil(VkCommandBuffer cmd, VkExtent2D extent)
    {
        clear(cmd, extent, VK_IMAGE_ASPECT_STENCIL_BIT);
    }

    /// Clears the depth the sphere surface wrote, keeping the stencil
    void clearDepth(VkCommandBuffer cmd, VkExtent2D extent)
    {
        clear(cmd, extent, VK_IMAGE_ASPECT_DEPTH_BIT);
    }

    /// Writes the sphere's far surface depth for the stencil count
    void drawSphereDepth(VkCommandBuffer cmd, VkDescriptorSet frameSet)
    {
        auto cfg = sphereDepth.get("section sphere depth");

        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, cfg.graphicsPipeline);
        vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, cfg.pipelineLayout,
            1, 1, &frameSet, 0, null);
        vkCmdDraw(cmd, 3, 1, 0, 0);
    }

    /// Fills the cut with the hatch or the solid colour
    void drawCap(VkCommandBuffer cmd, VkDescriptorSet frameSet)
    {
        auto cfg = cap.get("section cap");

        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, cfg.graphicsPipeline);
        vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, cfg.pipelineLayout,
            1, 1, &frameSet, 0, null);
        vkCmdDraw(cmd, 3, 1, 0, 0);
    }

    private void clear(VkCommandBuffer cmd, VkExtent2D extent, VkImageAspectFlags aspect)
    {
        VkClearAttachment attachment = {
            aspectMask: aspect,
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
}
