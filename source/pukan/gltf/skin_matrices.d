module pukan.gltf.skin_matrices;

import dlib.math;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.computation: Compute;

/// GPU kernel that calculates skin joint matrices:
/// jointMatrices[i] = skinRootInverse * transFromRoot[nodeIndices[i]] * inverseBindMatrices[i]
class SkinMatrices : Compute
{
    TransferBuffer transFromRootBuf; /// per-node transform relative to skin root, updated per frame
    TransferBuffer nodeIndicesBuf; /// joint index -> node index, static
    TransferBuffer invBindBuf; /// inverse bind matrices, static

    VkDescriptorBufferInfo transFromRootInfo;
    VkDescriptorBufferInfo nodeIndicesInfo;
    VkDescriptorBufferInfo invBindInfo;
    VkDescriptorBufferInfo jointsOutInfo;

    uint jointsCount;

    enum PushConstantSize = Matrix4x4f.sizeof;

    this(
        LogicalDevice dev,
        uint nodesCount,
        const(uint)[] nodesIndices,
        const(Matrix4x4f)[] inverseBindMatrices,
        MemoryBuffer jointsOutBuf,
        size_t jointsOutSize,
    )
    {
        jointsCount = cast(uint) nodesIndices.length;
        assert(inverseBindMatrices.length == jointsCount);

        transFromRootBuf = dev.create!TransferBuffer(nodesCount * Matrix4x4f.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        nodeIndicesBuf = dev.create!TransferBuffer(jointsCount * uint.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        invBindBuf = dev.create!TransferBuffer(jointsCount * Matrix4x4f.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);

        nodeIndicesBuf.cpuBuf[0 .. $] = cast(void[]) nodesIndices;
        invBindBuf.cpuBuf[0 .. $] = cast(void[]) inverseBindMatrices;

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
            VkDescriptorSetLayoutBinding(
                binding: 3,
                descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
            ),
        ];

        VkPushConstantRange pushConstant = {
            stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
            offset: 0,
            size: PushConstantSize,
        };

        super(
            dev,
            layoutBindings,
            cast(ubyte[]) import("skin_matrices.spv"),
            pushConstant,
        );

        transFromRootInfo = VkDescriptorBufferInfo(
            buffer: transFromRootBuf.gpuBuffer,
            offset: 0,
            range: transFromRootBuf.length,
        );

        nodeIndicesInfo = VkDescriptorBufferInfo(
            buffer: nodeIndicesBuf.gpuBuffer,
            offset: 0,
            range: nodeIndicesBuf.length,
        );

        invBindInfo = VkDescriptorBufferInfo(
            buffer: invBindBuf.gpuBuffer,
            offset: 0,
            range: invBindBuf.length,
        );

        jointsOutInfo = VkDescriptorBufferInfo(
            buffer: jointsOutBuf.buf,
            offset: 0,
            range: jointsOutSize,
        );

        bindBuffer(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, transFromRootInfo);
        bindBuffer(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, nodeIndicesInfo);
        bindBuffer(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, invBindInfo);
        bindBuffer(3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, jointsOutInfo);
        commitDescriptorWrites();
    }

    ~this()
    {
        if(transFromRootBuf)
            destroy(transFromRootBuf);

        if(nodeIndicesBuf)
            destroy(nodeIndicesBuf);

        if(invBindBuf)
            destroy(invBindBuf);
    }

    /// Uploads static data (nodeIndices, inverseBindMatrices) to GPU once
    void uploadStatic(scope CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        nodeIndicesBuf.uploadImmediate(commandPool, commandBuffer);
        invBindBuf.uploadImmediate(commandPool, commandBuffer);
    }

    /// Sets per-frame transform of each node relative to the skin root
    void setTransFromRoot(const(Matrix4x4f)[] transFromRoot)
    in(transFromRoot.length * Matrix4x4f.sizeof == transFromRootBuf.length)
    {
        transFromRootBuf.cpuBuf[0 .. $] = cast(void[]) transFromRoot;
    }

    /// Records upload of transFromRoot and dispatches the kernel
    void run(ref VkCommandBuffer cmdBuf, ref Matrix4x4f skinRootInverse)
    {
        transFromRootBuf.recordUpload(cmdBuf);

        VkBufferMemoryBarrier uploadBarrier = {
            sType: VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            srcAccessMask: VK_ACCESS_TRANSFER_WRITE_BIT,
            dstAccessMask: VK_ACCESS_SHADER_READ_BIT,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            buffer: transFromRootInfo.buffer,
            offset: 0,
            size: VK_WHOLE_SIZE,
        };

        vkCmdPipelineBarrier(
            cmdBuf,
            VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0, // dependencyFlags
            0, null, // memoryBarriers
            1, &uploadBarrier, // bufferMemoryBarriers
            0, null, // imageMemoryBarriers
        );

        dispatch(
            cmdBuf,
            &skinRootInverse,
            (jointsCount + 63) / 64,
            1,
            1,
        );

        VkBufferMemoryBarrier jointsOutBarrier = {
            sType: VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            srcAccessMask: VK_ACCESS_SHADER_WRITE_BIT,
            dstAccessMask: VK_ACCESS_SHADER_READ_BIT,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            buffer: jointsOutInfo.buffer,
            offset: 0,
            size: VK_WHOLE_SIZE,
        };

        vkCmdPipelineBarrier(
            cmdBuf,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_PIPELINE_STAGE_VERTEX_SHADER_BIT,
            0, // dependencyFlags
            0, null, // memoryBarriers
            1, &jointsOutBarrier, // bufferMemoryBarriers
            0, null, // imageMemoryBarriers
        );
    }
}