module pukan.vulkan.computation;

import pukan.vulkan.bindings;
import pukan.vulkan.descriptors: PoolAndLayoutInfo, bufferWriteDescriptor, imageWriteDescriptor;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.pipelines: PipelineFactory, PipelineKey;
import pukan.vulkan.shaders: ShaderDecl;

/// Base class for GPU compute kernels
abstract class Compute
{
    protected LogicalDevice device;
    protected PoolAndLayoutInfo poolAndLayout;
    protected VkDescriptorSet descriptorSet;

    protected VkPipelineLayout pipelineLayout;
    protected VkPipeline pipeline;
    protected uint pushConstantSize;
    /// Set when this run compiled the kernel instead of taking a stored record
    bool needsRecompilation;

    private PipelineFactory pipelines;
    private PipelineKey computeKey;
    private VkWriteDescriptorSet[] pendingWrites;

    this(
        LogicalDevice dev,
        PipelineFactory pipelines,
        ShaderDecl shader,
        VkSpecializationInfo* specialization = null,
    )
    {
        device = dev;
        this.pipelines = pipelines;

        auto layout = pipelines.declareCompute(shader, specialization);

        computeKey = layout.key;
        pipelineLayout = layout.pipelineLayout;
        pushConstantSize = shader.pushConstantRange.size;

        poolAndLayout = device.createDescriptorPool(layout.setLayout, shader.layoutBindings, 1);
        descriptorSet = device.allocateDescriptorSet(poolAndLayout);

        if(pipelines.eagerCompute)
            ensurePipeline();
    }

    private void ensurePipeline()
    {
        if(pipeline !is null)
            return;

        auto cfg = pipelines.acquireCompute(computeKey);

        pipeline = cfg.pipeline;
        pipelineLayout = cfg.pipelineLayout;
        needsRecompilation = cfg.needsRecompilation;
    }

    protected void bindBuffer(uint dstBinding, VkDescriptorType descriptorType, ref VkDescriptorBufferInfo bufferInfo)
    {
        pendingWrites ~= bufferWriteDescriptor(descriptorSet, dstBinding, descriptorType, bufferInfo);
    }

    protected void bindImage(uint dstBinding, VkDescriptorType descriptorType, ref VkDescriptorImageInfo imageInfo)
    {
        pendingWrites ~= imageWriteDescriptor(descriptorSet, dstBinding, descriptorType, imageInfo);
    }

    protected void commitDescriptorWrites()
    {
        device.updateDescriptorSets(pendingWrites);
        pendingWrites.length = 0;
    }

    protected void dispatch(VkCommandBuffer cmdBuf, const(void)* pushConstants, uint groupsX, uint groupsY, uint groupsZ)
    {
        ensurePipeline();

        vkCmdBindPipeline(cmdBuf, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);

        vkCmdBindDescriptorSets(
            cmdBuf,
            VK_PIPELINE_BIND_POINT_COMPUTE,
            pipelineLayout,
            0, // firstSet
            1, // descriptorSetCount
            &descriptorSet,
            0, // dynamicOffsetCount
            null,
        );

        if(pushConstants !is null)
            vkCmdPushConstants(
                cmdBuf,
                pipelineLayout,
                VK_SHADER_STAGE_COMPUTE_BIT,
                0, // offset
                pushConstantSize,
                pushConstants,
            );

        vkCmdDispatch(cmdBuf, groupsX, groupsY, groupsZ);
    }
}

struct Params
{
    uint M;
    uint N;
    uint K;
    float alpha;
    float beta;
}
