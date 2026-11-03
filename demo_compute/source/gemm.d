module gemm;

import pukan.graphics.common.shaders: shaderStage;
import pukan.vulkan.bindings;
import pukan.vulkan.commands: CommandPool;
import pukan.vulkan.computation: Compute, Params;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: MemoryBufferMappedToCPU, TransferBuffer;
import pukan.vulkan.pipelines: PipelineFactory;
import pukan.vulkan.requirements: Requirement;
import std.meta: AliasSeq;

class Gemm : Compute
{
    private alias requirements = AliasSeq!(
        Requirement!(VkPhysicalDeviceVulkan13Features.maintenance4),
        Requirement!(VkPhysicalDeviceLimits.maxComputeWorkGroupInvocations, 256),
        Requirement!(VkQueueFamilyProperties.queueFlags, VK_QUEUE_COMPUTE_BIT),
    );

    CommandPool cmdPool;
    VkCommandBuffer cmdBuf;

    TransferBuffer bufA;
    TransferBuffer bufB;
    MemoryBufferMappedToCPU bufC;

    VkDescriptorBufferInfo aInfo;
    VkDescriptorBufferInfo bInfo;
    VkDescriptorBufferInfo cInfo;

    enum ParamsSize = Params.sizeof;
    enum workgroupSizeX = 16;
    enum workgroupSizeY = 16;

    /// Verifies the requirements, then creates the kernel
    static Gemm create(LogicalDevice dev, PipelineFactory pipelines, uint M, uint N, uint K)
    {
        dev.ensureEnabled!requirements("Gemm");

        return new Gemm(dev, pipelines, M, N, K);
    }

    private this(LogicalDevice dev, PipelineFactory pipelines, uint M, uint N, uint K)
    {
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

        VkPushConstantRange pushConstant = {
            stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
            offset: 0,
            size: ParamsSize,
        };

        uint[2] workgroupSizes = [workgroupSizeX, workgroupSizeY];
        VkSpecializationMapEntry[2] mapEntries = [
            VkSpecializationMapEntry(constantID: 0, offset: 0, size: uint.sizeof),
            VkSpecializationMapEntry(constantID: 1, offset: uint.sizeof, size: uint.sizeof),
        ];
        VkSpecializationInfo specialization = {
            mapEntryCount: cast(uint) mapEntries.length,
            pMapEntries: mapEntries.ptr,
            dataSize: workgroupSizes.sizeof,
            pData: cast(const void*) workgroupSizes.ptr,
        };

        super(
            dev,
            pipelines,
            shaderStage!"gemm.spv"(
                VK_SHADER_STAGE_COMPUTE_BIT,
                layoutBindings,
                pushConstant,
            ),
            &specialization,
        );

        _M = M;
        _N = N;
        _K = K;

        cmdPool = dev.createCommandPool();
        cmdBuf = cmdPool.allocateBuffers(1)[0];

        bufA = dev.create!TransferBuffer(M*K*float.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        bufB = dev.create!TransferBuffer(K*N*float.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        bufC = dev.create!MemoryBufferMappedToCPU(M*N*float.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);

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

        bindBuffer(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, aInfo);
        bindBuffer(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, bInfo);
        bindBuffer(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, cInfo);
        commitDescriptorWrites();
    }

    ~this()
    {
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

                auto params = Params(M, N, K, alpha, beta);
                dispatch(
                    cmdBuf,
                    &params,
                    (N + workgroupSizeX - 1) / workgroupSizeX,
                    (M + workgroupSizeY - 1) / workgroupSizeY,
                    1,
                );
            }
        );
    }
}