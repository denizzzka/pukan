module pukan.background;

import pukan.vulkan.bindings;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.pipelines: FixedState, PipelineFactory, RenderTechnique;
import pukan.vulkan.renderpass: DefaultRenderPass;

/// Screen-space checkerboard drawn in the 2D subpass
class Checkerboard
{
    private VkPipeline pipeline;

    this(LogicalDevice device, PipelineFactory pipelines, DefaultRenderPass renderPass)
    {
        const technique = pipelines.declare(RenderTechnique(
            name: "checkerboard",
            stages: [
                device.uploadShaderToGPU(
                    cast(ubyte[]) import("checkerboard_vert.spv"),
                    VK_SHADER_STAGE_VERTEX_BIT,
                    null,
                ),
                device.uploadShaderToGPU(
                    cast(ubyte[]) import("checkerboard_frag.spv"),
                    VK_SHADER_STAGE_FRAGMENT_BIT,
                    null,
                ),
            ],
            state: FixedState(
                cullMode: VK_CULL_MODE_NONE,
                depthTestEnable: VK_FALSE,
                depthWriteEnable: VK_FALSE,
            ),
        ), 1);

        pipeline = pipelines.acquire(technique, renderPass, 0).graphicsPipeline;
    }

    void draw(VkCommandBuffer commandBuffer)
    {
        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        vkCmdDraw(commandBuffer, 3, 1, 0, 0);
    }
}
