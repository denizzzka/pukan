module pukan.vulkan.computation;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.shaders: ShaderInfo;

struct Params
{
    uint M;
    uint N;
    uint K;
    float alpha;
    float beta;
}

class Gemm
{
    LogicalDevice device;
    CommandPool cmdPool;
    VkCommandBuffer cmdBuf;

    TransferBuffer bufA;
    TransferBuffer bufB;
    MemoryBufferMappedToCPU bufC;

    PoolAndLayoutInfo poolAndLayout;
    VkDescriptorSet descriptorSet;

    VkDescriptorBufferInfo aInfo;
    VkDescriptorBufferInfo bInfo;
    VkDescriptorBufferInfo cInfo;

    VkPipelineLayout pipelineLayout;
    VkPipeline pipeline;

    enum ParamsSize = Params.sizeof;

    this(LogicalDevice dev, uint M, uint N, uint K)
    {
        device = dev;
        _M = M;
        _N = N;
        _K = K;
        cmdPool = dev.createCommandPool();
        cmdBuf = cmdPool.allocateBuffers(1)[0];

        bufA = dev.create!TransferBuffer(M*K*float.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        bufB = dev.create!TransferBuffer(K*N*float.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        bufC = dev.create!MemoryBufferMappedToCPU(M*N*float.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);

        VkDescriptorSetLayoutBinding[] layoutBindings = [
            VkDescriptorSetLayoutBinding(
                binding: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: 1,
                descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: 2,
                descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
            ),
        ];

        poolAndLayout = device.createDescriptorPool(layoutBindings, 1);
        descriptorSet = device.allocateDescriptorSet(poolAndLayout);

        aInfo = VkDescriptorBufferInfo(
            buffer: bufA.gpuBuffer,
            offset: 0,
            range: bufA.length,
        );

        bInfo = VkDescriptorBufferInfo(
            buffer: bufB.gpuBuffer,
            offset: 0,
            range: bufB.length,
        );

        cInfo = VkDescriptorBufferInfo(
            buffer: bufC.buf,
            offset: 0,
            range: bufC.cpuBuf.length,
        );

        VkWriteDescriptorSet[] descriptorWrites = [
            bufferWriteDescriptor(descriptorSet, 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, aInfo),
            bufferWriteDescriptor(descriptorSet, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, bInfo),
            bufferWriteDescriptor(descriptorSet, 2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, cInfo),
        ];

        device.updateDescriptorSets(descriptorWrites);

        VkPushConstantRange pushConstant = {
            stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
            offset: 0,
            size: ParamsSize,
        };

        auto shader = device.uploadShaderToGPU(
            cast(ubyte[]) import("gemm.spv"),
            VK_SHADER_STAGE_COMPUTE_BIT,
            layoutBindings,
            pushConstant,
        );

        pipelineLayout = createPipelineLayout(device, [poolAndLayout.descriptorSetLayout], [pushConstant]);
        scope(failure) destroy(pipelineLayout);

        auto pipelineCreateInfo = VkComputePipelineCreateInfo(
            sType: VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            stage: shader.createShaderStageInfo,
            layout: pipelineLayout,
            basePipelineHandle: null,
            basePipelineIndex: -1,
        );

        pipeline = device.createComputePipelines([pipelineCreateInfo])[0];
    }

    ~this()
    {
        if(pipelineLayout)
            vkDestroyPipelineLayout(device, pipelineLayout, device.alloc);

        if(cmdPool)
            destroy(cmdPool);

        if(bufA)
            destroy(bufA);

        if(bufB)
            destroy(bufB);

        if(bufC)
            destroy(bufC);
    }

    void setA(const float[] data)
    in(data.length * float.sizeof == bufA.length)
    {
        bufA.cpuBuf[0 .. $] = cast(void[]) data;
    }

    void setB(const float[] data)
    in(data.length * float.sizeof == bufB.length)
    {
        bufB.cpuBuf[0 .. $] = cast(void[]) data;
    }

    void setC(const float[] data)
    in(data.length * float.sizeof == bufC.cpuBuf.length)
    {
        bufC.cpuBuf[0 .. $] = cast(void[]) data;
    }

    float[] downloadC() const
    {
        return cast(float[]) bufC.cpuBuf;
    }

    uint M() const => _M;
    uint N() const => _N;
    uint K() const => _K;

    private uint _M;
    private uint _N;
    private uint _K;

    void run(float alpha = 1.0f, float beta = 0.0f)
    {
        const M = _M;
        const N = _N;
        const K = _K;

        cmdPool.recordOneTimeAndSubmit(
            cmdBuf,
            (cmdBuf) {
                bufA.recordUpload(cmdBuf);
                bufB.recordUpload(cmdBuf);

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

                auto params = Params(M, N, K, alpha, beta);
                vkCmdPushConstants(
                    cmdBuf,
                    pipelineLayout,
                    VK_SHADER_STAGE_COMPUTE_BIT,
                    0, // offset
                    ParamsSize,
                    &params,
                );

                enum localSize = 16;

                vkCmdDispatch(
                    cmdBuf,
                    (N + localSize - 1) / localSize,
                    (M + localSize - 1) / localSize,
                    1,
                );
            }
        );
    }
}