module pukan.background;

import pukan.vulkan.bindings;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.pipelines: DefaultGraphicsPipelineInfoCreator;
import pukan.vulkan.renderpass: DefaultRenderPass;
import pukan.vulkan.shaders: ShaderInfo;

private struct NoVertex
{
    static VkVertexInputBindingDescription[] getBindingDescriptions()
    {
        return null;
    }

    static VkVertexInputAttributeDescription[] getAttributeDescriptions()
    {
        return null;
    }
}

/// Screen-space checkerboard drawn in the 2D subpass
class Checkerboard
{
    private DefaultGraphicsPipelineInfoCreator!NoVertex pipelineCreator;
    private VkPipeline pipeline;

    this(LogicalDevice device, DefaultRenderPass renderPass)
    {
        ShaderInfo[] stages = [
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
        ];

        pipelineCreator = new DefaultGraphicsPipelineInfoCreator!NoVertex(device, [], stages, renderPass);
        pipelineCreator.depthStencil.depthTestEnable = VK_FALSE;
        pipelineCreator.depthStencil.depthWriteEnable = VK_FALSE;
        pipelineCreator.rasterizerInfo.cullMode = VK_CULL_MODE_NONE;

        pipeline = device.createGraphicsPipelines([pipelineCreator.pipelineCreateInfo])[0];
    }

    void draw(VkCommandBuffer commandBuffer)
    {
        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        vkCmdDraw(commandBuffer, 3, 1, 0, 0);
    }
}
