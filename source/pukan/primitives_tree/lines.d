module pukan.primitives_tree.lines;

import dlib.math: Matrix4x4f, Vector2f, Vector4f;
import pukan.primitives_tree: DrawablePrimitive;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.pipelines: FixedState, GraphicsPipelineCfg, PipelineFactory, RenderTechnique;

struct LineInstance
{
    Vector4f p0;    /// xyz and width in pixels
    Vector4f p1;    /// xyz
    Vector4f color; /// rgba
}

private struct LinePush
{
    Matrix4x4f mvp;
    Vector2f viewport;
}

private ShaderVertexInput vertexInput()
{
    return ShaderVertexInput(
        [
            VkVertexInputBindingDescription(
                binding: 0,
                stride: 2 * float.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
            VkVertexInputBindingDescription(
                binding: 1,
                stride: LineInstance.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_INSTANCE,
            ),
        ],
        [
            VkVertexInputAttributeDescription(
                binding: 0,
                location: 0,
                format: VK_FORMAT_R32G32_SFLOAT,
                offset: 0,
            ),
            VkVertexInputAttributeDescription(
                binding: 1,
                location: 1,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: LineInstance.p0.offsetof,
            ),
            VkVertexInputAttributeDescription(
                binding: 1,
                location: 2,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: LineInstance.p1.offsetof,
            ),
            VkVertexInputAttributeDescription(
                binding: 1,
                location: 3,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: LineInstance.color.offsetof,
            ),
        ],
    );
}

/// Screen-space expanded line segments, for debug output
class LineRenderer : DrawablePrimitive
{
    private VkExtent2D viewport;
    private uint lineCount;
    private size_t instanceCapacity;

    private MemoryBufferMappedToCPU vertexBuffer;
    private MemoryBufferMappedToCPU instanceBuffer;

    GraphicsPipelineCfg pipelineCfg;

    this(
        LogicalDevice device,
        PipelineFactory pipelines,
        RenderPass renderPass,
        VkExtent2D viewport,
        bool overlay = false,
        size_t instanceCapacity = 4096,
    )
    in(instanceCapacity > 0)
    {
        this.viewport = viewport;
        this.instanceCapacity = instanceCapacity;

        const technique = pipelines.declare(RenderTechnique(
            name: overlay ? "lines overlay" : "lines",
            stages: shaderStages(device),
            state: FixedState(
                topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
                cullMode: VK_CULL_MODE_NONE,
                depthTestEnable: overlay ? VK_FALSE : VK_TRUE,
                depthWriteEnable: overlay ? VK_FALSE : VK_TRUE,
            ),
        ), 1);

        pipelineCfg = pipelines.acquire(technique, renderPass, 1);

        vertexBuffer = device.create!MemoryBufferMappedToCPU(
            4 * 2 * float.sizeof,
            VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        (cast(float[]) vertexBuffer.cpuBuf)[] = [
            0, -1,
            0,  1,
            1, -1,
            1,  1,
        ];

        instanceBuffer = device.create!MemoryBufferMappedToCPU(
            instanceCapacity * LineInstance.sizeof,
            VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
    }

    ~this()
    {
        if(instanceBuffer)
            destroy(instanceBuffer);

        if(vertexBuffer)
            destroy(vertexBuffer);
    }

    void setViewport(VkExtent2D viewport)
    {
        this.viewport = viewport;
    }

    void setLines(LineInstance[] lines)
    in(lines.length <= instanceCapacity)
    {
        lineCount = cast(uint) lines.length;

        auto dst = cast(LineInstance[]) instanceBuffer.cpuBuf;
        dst[0 .. lines.length] = lines;
    }

    private static ShaderInfo[] shaderStages(LogicalDevice device)
    {
        return [
            device.uploadShaderToGPU(
                cast(ubyte[]) import("line_vert.spv"),
                VK_SHADER_STAGE_VERTEX_BIT,
                null,
                VkPushConstantRange(
                    stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                    offset: 0,
                    size: LinePush.sizeof,
                ),
                vertexInput(),
            ),
            device.uploadShaderToGPU(
                cast(ubyte[]) import("line_frag.spv"),
                VK_SHADER_STAGE_FRAGMENT_BIT,
                null,
            ),
        ];
    }

    override void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
    }

    override void drawingBufferFilling(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f trans)
    {
        if(lineCount == 0)
            return;

        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);

        LinePush push;
        push.mvp = trans;
        push.viewport = Vector2f(cast(float) viewport.width, cast(float) viewport.height);
        vkCmdPushConstants(
            buf,
            pipeline.pipelineLayout,
            VK_SHADER_STAGE_VERTEX_BIT,
            0,
            cast(uint) push.sizeof,
            &push,
        );

        VkBuffer[2] buffers = [vertexBuffer.buf, instanceBuffer.buf];
        VkDeviceSize[2] offsets = [0, 0];
        vkCmdBindVertexBuffers(buf, 0, 2, buffers.ptr, offsets.ptr);
        vkCmdDraw(buf, 4, lineCount, 0, 0);
    }
}
