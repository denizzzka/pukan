module pukan.background;

import dlib.math: Vector3f, Vector4f;
import pukan.vulkan.bindings;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.pipelines: FixedState, GraphicsPipelineCfg, PipelineFactory, RenderTechnique;
import pukan.vulkan.renderpass: DefaultRenderPass;

/// What the render pass clears to before the scene draws
enum BackgroundMode: uint
{
    checkerboard,
    color,
    sky,
}

/// Full-screen background: a checkerboard, a solid colour or a sky gradient
class Background
{
    private GraphicsPipelineCfg pipeline;
    private BackgroundMode mode;
    private Vector4f top;
    private Vector4f horizon;
    private Vector4f groundHorizon;
    private Vector4f groundBottom;
    private float energy = 1.0f;

    this(LogicalDevice device, PipelineFactory pipelines, DefaultRenderPass renderPass)
    {
        const technique = pipelines.declare(RenderTechnique(
            name: "background",
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
                    VkPushConstantRange(
                        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
                        offset: 0,
                        size: BackgroundData.sizeof,
                    ),
                ),
            ],
            state: FixedState(
                cullMode: VK_CULL_MODE_NONE,
                depthTestEnable: VK_FALSE,
                depthWriteEnable: VK_FALSE,
            ),
        ), 1);

        pipeline = pipelines.acquire(technique, renderPass, 0);
    }

    void setColor(Vector3f color, float energy = 1.0f)
    {
        mode = BackgroundMode.color;
        horizon = Vector4f(color.x, color.y, color.z, 1);
        this.energy = energy;
    }

    void setSky(Vector3f top, Vector3f horizon, Vector3f groundHorizon, Vector3f groundBottom, float energy = 1.0f)
    {
        mode = BackgroundMode.sky;
        this.top = Vector4f(top.x, top.y, top.z, 1);
        this.horizon = Vector4f(horizon.x, horizon.y, horizon.z, 1);
        this.groundHorizon = Vector4f(groundHorizon.x, groundHorizon.y, groundHorizon.z, 1);
        this.groundBottom = Vector4f(groundBottom.x, groundBottom.y, groundBottom.z, 1);
        this.energy = energy;
    }

    void draw(VkCommandBuffer commandBuffer, VkExtent2D extent)
    {
        const data = BackgroundData(
            top,
            horizon,
            groundHorizon,
            groundBottom,
            Vector4f(cast(float) mode, cast(float) extent.height, energy, 0),
        );

        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);
        vkCmdPushConstants(
            commandBuffer,
            pipeline.pipelineLayout,
            VK_SHADER_STAGE_FRAGMENT_BIT,
            0,
            cast(uint) BackgroundData.sizeof,
            cast(const void*) &data,
        );
        vkCmdDraw(commandBuffer, 3, 1, 0, 0);
    }
}

/// Mirrors the push constant block in checkerboard.frag
private struct BackgroundData
{
    Vector4f top;
    Vector4f horizon;
    Vector4f groundHorizon;
    Vector4f groundBottom;
    Vector4f params; // x = mode, y = height, z = energy
}
