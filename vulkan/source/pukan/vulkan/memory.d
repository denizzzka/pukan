module pukan.vulkan.memory;

import pukan.vulkan.commands: CommandPool;
import pukan.vulkan.helpers: vkCheck;
import pukan.vulkan.logical_device: LogicalDevice;

private void releaseBuffer(LogicalDevice device, void* handle, VkAllocationCallbacks* alloc)
{
    vkDestroyBuffer(device, cast(VkBuffer) handle, alloc);
}

private void releaseMemory(LogicalDevice device, void* handle, VkAllocationCallbacks* alloc)
{
    vkFreeMemory(device, cast(VkDeviceMemory) handle, alloc);
}

package mixin template Memory()
{
    import core.atomic: atomicLoad, atomicOp, atomicStore;

    private shared ulong deviceLocalBytes;
    private shared ulong hostVisibleBytes;
    private shared size_t deviceMemoryAllocations;
    private shared ulong uploadedBytesCount;

    /// Allocates memory the caller frees
    VkDeviceMemory allocateMemory(ref VkMemoryAllocateInfo allocInfo)
    {
        VkDeviceMemory memory;
        vkAllocateMemory(this.device, &allocInfo, this.alloc, &memory).vkCheck;

        return memory;
    }

    void addDeviceMemory(size_t bytes, VkMemoryPropertyFlags flags)
    {
        atomicOp!"+="(deviceMemoryAllocations, 1);

        if(flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
            atomicOp!"+="(deviceLocalBytes, cast(ulong) bytes);
        if(flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
            atomicOp!"+="(hostVisibleBytes, cast(ulong) bytes);
    }

    void removeDeviceMemory(size_t bytes, VkMemoryPropertyFlags flags)
    {
        atomicOp!"-="(deviceMemoryAllocations, 1);

        if(flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
            atomicOp!"-="(deviceLocalBytes, cast(ulong) bytes);
        if(flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
            atomicOp!"-="(hostVisibleBytes, cast(ulong) bytes);
    }

    ulong deviceLocalMemoryBytes() const => atomicLoad(deviceLocalBytes);
    ulong hostVisibleMemoryBytes() const => atomicLoad(hostVisibleBytes);
    size_t deviceMemoryAllocationCount() const => atomicLoad(deviceMemoryAllocations);

    void addUploadedBytes(size_t bytes) { atomicOp!"+="(uploadedBytesCount, cast(ulong) bytes); }
    ulong uploadedBytes() const => atomicLoad(uploadedBytesCount);
    void resetUploadedBytes() { atomicStore(uploadedBytesCount, 0); }

    /// Creates a buffer the caller frees
    VkBuffer createBuffer(ref VkBufferCreateInfo createInfo)
    {
        VkBuffer buffer;
        vkCreateBuffer(this.device, &createInfo, this.alloc, &buffer).vkCheck;

        return buffer;
    }
}

import pukan.vulkan.bindings;

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
        vkMapMemory(device, deviceMemory, 0 /*offset*/, size, 0 /*flags*/, cast(void**) &createdBuf).vkCheck;

        cpuBuf = createdBuf[0 .. size];
    }

    ~this()
    {
        if(deviceMemory)
            vkUnmapMemory(device, deviceMemory);
    }
}

//TODO: Incorporate into LogicalDevice by using mixin template?
class MemoryBuffer : DeviceMemory
{
    VkBuffer buf;
    alias this = buf;

    this(LogicalDevice device, ref VkBufferCreateInfo createInfo, in VkMemoryPropertyFlags propFlags)
    {
        buf = device.createBuffer(createInfo);

        VkMemoryRequirements memRequirements;
        vkGetBufferMemoryRequirements(device.device, buf, &memRequirements);

        super(device, memRequirements, propFlags);

        vkBindBufferMemory(device, buf, deviceMemory, 0 /*memoryOffset*/).vkCheck;
    }

    ~this()
    {
        if(!buf)
            return;

        auto dev = device;
        auto releasing = buf;
        buf = null;

        dev.retire(&releaseBuffer, cast(void*) releasing);
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
    LogicalDevice device;
    VkDeviceMemory deviceMemory;
    private size_t allocationSize;
    private VkMemoryPropertyFlags propFlags;

    this(LogicalDevice device, in VkMemoryRequirements memRequirements, in VkMemoryPropertyFlags propFlags)
    {
        VkMemoryAllocateInfo allocInfo = {
            sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            allocationSize: memRequirements.size,
            memoryTypeIndex: device.physicalDevice.findMemoryType(memRequirements.memoryTypeBits, propFlags),
        };

        this.device = device;
        this.allocationSize = allocInfo.allocationSize;
        this.propFlags = propFlags;

        deviceMemory = device.allocateMemory(allocInfo);
        device.addDeviceMemory(allocInfo.allocationSize, propFlags);
    }

    ~this()
    {
        if(deviceMemory == VkDeviceMemory.init)
            return;

        auto dev = device;
        auto releasing = deviceMemory;
        auto bytes = allocationSize;
        auto flags = propFlags;
        deviceMemory = VkDeviceMemory.init;

        dev.removeDeviceMemory(bytes, flags);
        dev.retire(&releaseMemory, cast(void*) releasing);
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

        destroy(gpuBuffer);
        gpuBuffer = null;
    }

    void recordUpload(VkCommandBuffer buf)
    {
        prepareGPU();

        gpuBuffer.recordCopyBuffer(buf, cpuBuffer.buf, gpuBuffer.buf, cpuBuf.length);
        device.addUploadedBytes(cpuBuf.length);
    }
}
