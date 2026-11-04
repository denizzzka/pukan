module pukan.vulkan.memory;

import core.atomic: atomicLoad, atomicOp, atomicStore;
import pukan.vulkan.bindings;
import pukan.vulkan.commands: CommandPool;
import pukan.vulkan.helpers: vkCheck;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.resources.release: ReleaseQueue;
import pukan.vulkan.resources.vkobj: VkObj;
import std.algorithm: move;

private shared ulong deviceLocalBytes;
private shared ulong hostVisibleBytes;
private shared size_t deviceMemoryAllocations;
private shared ulong uploadedBytesCount;

package void memoryAddAllocation(size_t bytes, VkMemoryPropertyFlags flags)
{
    atomicOp!"+="(deviceMemoryAllocations, 1);

    if(flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
        atomicOp!"+="(deviceLocalBytes, cast(ulong) bytes);
    if(flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
        atomicOp!"+="(hostVisibleBytes, cast(ulong) bytes);
}

package void memoryRemoveAllocation(size_t bytes, VkMemoryPropertyFlags flags)
{
    atomicOp!"-="(deviceMemoryAllocations, 1);

    if(flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
        atomicOp!"-="(deviceLocalBytes, cast(ulong) bytes);
    if(flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
        atomicOp!"-="(hostVisibleBytes, cast(ulong) bytes);
}

package ulong memoryDeviceLocal() => atomicLoad(deviceLocalBytes);
package ulong memoryHostVisible() => atomicLoad(hostVisibleBytes);
package size_t memoryAllocationCount() => atomicLoad(deviceMemoryAllocations);

package void memoryAddUploaded(size_t bytes)
{
    atomicOp!"+="(uploadedBytesCount, cast(ulong) bytes);
}
package ulong memoryUploadedBytes() => atomicLoad(uploadedBytesCount);
package void memoryResetUploaded() => atomicStore(uploadedBytesCount, 0);

package mixin template Memory()
{
    import pukan.vulkan.memory: memoryAddUploaded, memoryAllocationCount,
        memoryDeviceLocal, memoryHostVisible, memoryResetUploaded, memoryUploadedBytes;

    void addUploadedBytes(size_t bytes) => memoryAddUploaded(bytes);
    ulong uploadedBytes() const => memoryUploadedBytes();
    void resetUploadedBytes() => memoryResetUploaded();

    ulong deviceLocalMemoryBytes() const => memoryDeviceLocal();
    ulong hostVisibleMemoryBytes() const => memoryHostVisible();
    size_t deviceMemoryAllocationCount() const => memoryAllocationCount();
}

class MemoryBufferMappedToCPU : MemoryBuffer
{
    void[] cpuBuf; /// CPU-mapped memory buffer

    this(LogicalDevice device, size_t size, VkBufferUsageFlags usageFlags)
    {
        VkBufferCreateInfo createInfo = {
            sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            size: size,
            usage: usageFlags,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
        };

        super(device, createInfo, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);

        void* createdBuf;
        vkMapMemory(device.device, deviceMemory, 0 /*offset*/, size, 0 /*flags*/, cast(void**) &createdBuf).vkCheck;

        cpuBuf = createdBuf[0 .. size];
    }

    ~this()
    {
        if(cpuBuf.length && !queue.isClosed)
            vkUnmapMemory(queue.device, deviceMemory);
    }
}

class MemoryBuffer : DeviceMemory
{
    private VkObj!VkBuffer bufObj;

    /// The buffer this object owns
    @property ref VkBuffer buf() => bufObj.vk;

    alias buf this;

    this(LogicalDevice device, ref VkBufferCreateInfo createInfo, in VkMemoryPropertyFlags propFlags)
    {
        auto created = VkObj!VkBuffer(device.releaseQueue, createInfo);

        VkMemoryRequirements memRequirements;
        vkGetBufferMemoryRequirements(device.device, created.vk, &memRequirements);

        super(device, memRequirements, propFlags);

        bufObj = move(created);

        vkBindBufferMemory(device.device, buf, deviceMemory, 0 /*memoryOffset*/).vkCheck;
    }

    //TODO: static?
    void recordCopyBuffer(VkCommandBuffer cmdBuf, VkBuffer srcBuffer, VkBuffer dstBuffer, VkDeviceSize size)
    {
        VkBufferCopy copyRegion = {
            size: size,
        };

        vkCmdCopyBuffer(cmdBuf, srcBuffer, dstBuffer, 1, &copyRegion);
    }

    /// begin-copy-end-submit
    //TODO: static?
    void copyBufferImmediateSubmit(CommandPool cmdPool, VkCommandBuffer buf, VkBuffer srcBuffer, VkBuffer dstBuffer, VkDeviceSize size)
    {
        cmdPool.recordOneTimeAndSubmit(
            buf,
            (cmdBuf) => recordCopyBuffer(cmdBuf, srcBuffer, dstBuffer, size)
        );
    }
}

class DeviceMemory
{
    private VkObj!VkDeviceMemory memoryObj;
    private size_t allocationSize;
    private VkMemoryPropertyFlags propFlags;

    /// Where releases wait for the frames in flight
    package ReleaseQueue queue;

    /// The allocation this object owns
    @property ref VkDeviceMemory deviceMemory() => memoryObj.vk;

    this(LogicalDevice device, in VkMemoryRequirements memRequirements, in VkMemoryPropertyFlags propFlags)
    {
        VkMemoryAllocateInfo allocInfo = {
            sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            allocationSize: memRequirements.size,
            memoryTypeIndex: device.physicalDevice.findMemoryType(memRequirements.memoryTypeBits, propFlags),
        };

        queue = device.releaseQueue;
        this.allocationSize = allocInfo.allocationSize;
        this.propFlags = propFlags;

        memoryObj = VkObj!VkDeviceMemory(queue, allocInfo);
        memoryAddAllocation(allocInfo.allocationSize, propFlags);
    }

    ~this()
    {
        if(memoryObj.isAlive)
            memoryRemoveAllocation(allocationSize, propFlags);
    }
}

/// TransferBuffer that additionally supports reading data back from GPU
class ReadableTransferBuffer : TransferBuffer
{
    this(LogicalDevice device, size_t size, VkBufferUsageFlags mergeUsageFlags = VK_BUFFER_USAGE_TRANSFER_DST_BIT)
    {
        auto staging = device.create!MemoryBufferMappedToCPU(
            size,
            VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        );

        super(device, staging, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | mergeUsageFlags);
    }

    void recordDownload(VkCommandBuffer buf)
    {
        gpuBuffer.recordCopyBuffer(buf, gpuBuffer.buf, cpuBuffer.buf, cpuBuf.length);
    }

    void downloadImmediate(CommandPool commandPool, ref VkCommandBuffer buf)
    {
        gpuBuffer.copyBufferImmediateSubmit(commandPool, buf, gpuBuffer.buf, cpuBuffer.buf, cpuBuf.length);
    }
}

/// Ability to transfer data into GPU
class TransferBuffer
{
    LogicalDevice device;
    MemoryBufferMappedToCPU cpuBuffer;
    MemoryBuffer gpuBuffer;
    private VkBufferUsageFlags usage;

    this(LogicalDevice device, size_t size, VkBufferUsageFlags mergeUsageFlags = VK_BUFFER_USAGE_TRANSFER_DST_BIT)
    {
        this.device = device;

        auto cpuBuffer = device.create!MemoryBufferMappedToCPU(size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);

        this(device, cpuBuffer, mergeUsageFlags);
    }

    this(LogicalDevice device, MemoryBufferMappedToCPU cpuBuffer, VkBufferUsageFlags mergeUsageFlags = VK_BUFFER_USAGE_TRANSFER_DST_BIT)
    {
        assert(cpuBuffer);
        assert(cpuBuffer.cpuBuf.length > 0);

        this.device = device;
        this.cpuBuffer = cpuBuffer;
        this.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT | mergeUsageFlags;

        prepareGPU();
    }

    ~this()
    {
        releaseGPU();
        destroy(cpuBuffer);
    }

    auto ref cpuBuf() => cpuBuffer.cpuBuf;
    auto cpuBuf() const => cpuBuffer.cpuBuf;
    uint length() const => cast(uint) cpuBuffer.cpuBuf.length;

    /// Creates the GPU copy again after `releaseGPU`; the CPU data stays
    void prepareGPU()
    {
        if(gpuBuffer !is null)
            return;

        VkBufferCreateInfo dstBufInfo = {
            sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            size: cpuBuffer.cpuBuf.length,
            usage: usage,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
        };

        gpuBuffer = device.create!MemoryBuffer(dstBufInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    }

    /// Drops the GPU copy; `prepareGPU` and an upload bring it back
    void releaseGPU()
    {
        if(gpuBuffer is null)
            return;

        // A frame in flight may still read the copy
        device.releaseQueue.retireHolder(gpuBuffer);
        gpuBuffer = null;
    }

    void recordUpload(VkCommandBuffer buf)
    {
        prepareGPU();

        gpuBuffer.recordCopyBuffer(buf, cpuBuffer.buf, gpuBuffer.buf, cpuBuf.length);
        device.addUploadedBytes(cpuBuf.length);
    }
}
