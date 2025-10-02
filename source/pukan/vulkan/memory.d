module pukan.vulkan.memory;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;

class MemoryBufferMappedToCPU : MemoryBuffer
{
    void[] cpuBuf; /// CPU-mapped memory buffer

    this(LogicalDevice device, size_t size, VkBufferUsageFlags usageFlags)
    {
        VkBufferCreateInfo createInfo = {
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
class MemoryBuffer : MemoryBufferBase
{
    VkBuffer buf;
    alias this = buf;

    this(LogicalDevice device, ref VkBufferCreateInfo createInfo, in VkMemoryPropertyFlags propFlags)
    {
        vkCall(device.device, &createInfo, device.backend.allocator, &buf);

        VkMemoryRequirements memRequirements;
        vkGetBufferMemoryRequirements(device.device, buf, &memRequirements);

        super(device, memRequirements, propFlags);

        vkBindBufferMemory(device, buf, deviceMemory, 0 /*memoryOffset*/).vkCheck;
    }

    ~this()
    {
        if(buf)
            vkDestroyBuffer(device.device, buf, device.backend.allocator);
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

class MemoryBufferBase
{
    LogicalDevice device;
    VkDeviceMemory deviceMemory;

    this(LogicalDevice dev, in VkMemoryRequirements memRequirements, in VkMemoryPropertyFlags propFlags)
    {
        device = dev;

        VkMemoryAllocateInfo allocInfo = {
            allocationSize: memRequirements.size,
            memoryTypeIndex: device.backend.findMemoryType(memRequirements.memoryTypeBits, propFlags),
        };

        vkCall(device.device, &allocInfo, device.backend.allocator, &deviceMemory);
    }

    ~this()
    {
        if(deviceMemory)
            vkFreeMemory(device.device, deviceMemory, device.backend.allocator);
    }
}

/// Ability to transfer data into GPU
class TransferBuffer
{
    LogicalDevice device;
    MemoryBufferMappedToCPU cpuBuffer;
    MemoryBuffer gpuBuffer;

    this(LogicalDevice device, size_t size, VkBufferUsageFlags mergeUsageFlags = VK_BUFFER_USAGE_TRANSFER_DST_BIT)
    {
        this.device = device;

        cpuBuffer = device.create!MemoryBufferMappedToCPU(size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,);

        VkBufferCreateInfo dstBufInfo = {
            size: size,
            usage: VK_BUFFER_USAGE_TRANSFER_DST_BIT | mergeUsageFlags,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
        };

        gpuBuffer = device.create!MemoryBuffer(dstBufInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    }

    ~this()
    {
        destroy(gpuBuffer);
        destroy(cpuBuffer);
    }

    auto ref cpuBuf() => cpuBuffer.cpuBuf;

    void uploadImmediate(CommandPool commandPool, VkCommandBuffer buf)
    {
        // Copy host RAM buffer to GPU RAM
        gpuBuffer.copyBufferImmediateSubmit(commandPool, buf, cpuBuffer.buf, gpuBuffer.buf, cpuBuf.length);
    }

    void recordUpload(VkCommandBuffer buf)
    {
        gpuBuffer.recordCopyBuffer(buf, cpuBuffer.buf, gpuBuffer.buf, cpuBuf.length);
    }
}
