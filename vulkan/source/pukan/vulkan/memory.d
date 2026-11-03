module pukan.vulkan.memory;

package mixin template Memory()
{
    import core.atomic: atomicLoad, atomicOp, atomicStore;
    import lockfree.list: LockFreeList;

    private LockFreeList!VkDeviceMemory deviceMemoryChunks;
    private shared ulong deviceLocalBytes;
    private shared ulong hostVisibleBytes;
    private shared size_t deviceMemoryAllocations;
    private shared ulong uploadedBytesCount;

    auto allocateDeviceMemory(ref VkMemoryAllocateInfo allocInfo)
    {
        return deviceMemoryChunks.insertOne((mem){
            vkAllocateMemory(this.device, &allocInfo, this.alloc, &mem).vkCheck;
        });
    }

    void addDeviceMemory(size_t bytes, VkMemoryPropertyFlags flags)
    {
        atomicOp!"+="(deviceMemoryAllocations, 1);

        if(flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
            atomicOp!"+="(deviceLocalBytes, cast(ulong) bytes);
        if(flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
            atomicOp!"+="(hostVisibleBytes, cast(ulong) bytes);
    }

    ulong deviceLocalMemoryBytes() const => atomicLoad(deviceLocalBytes);
    ulong hostVisibleMemoryBytes() const => atomicLoad(hostVisibleBytes);
    size_t deviceMemoryAllocationCount() const => atomicLoad(deviceMemoryAllocations);

    void addUploadedBytes(size_t bytes) { atomicOp!"+="(uploadedBytesCount, cast(ulong) bytes); }
    ulong uploadedBytes() const => atomicLoad(uploadedBytesCount);
    void resetUploadedBytes() { atomicStore(uploadedBytesCount, 0); }

    private LockFreeList!VkBuffer buffers;

    LockFreeList!(VkBuffer).Elem createBuffer(ref VkBufferCreateInfo createInfo)
    {
        return buffers.insertOne((e){
            vkCreateBuffer(this.device, &createInfo, this.alloc, &e).vkCheck;
        });
    }

    private LockFreeList!(VkBuffer[]) buffersArrays;

    auto createBuffersArray(/*in*/ VkBufferCreateInfo createInfo, size_t num = 1)
    {
        return buffersArrays.insertOne((ref arr){
            arr.length = num;

            foreach(ref e; arr)
                vkCreateBuffer(device, cast() &createInfo, alloc, &e).vkCheck;

            scope(failure) destroyBuffers(arr);
        });
    }

    private void destroyBuffers(T)(T arr)
    {
        foreach(ref e; arr)
            vkDestroyBuffer(this.device, e, this.alloc);
    }

    private void memoryDtor()
    {
        foreach(arr; buffersArrays)
            destroyBuffers(arr);

        destroyBuffers(buffers);

        foreach(e; deviceMemoryChunks)
            vkFreeMemory(this.device, e, this.alloc);
    }
}

import lockfree.list: LockFreeList;

alias MemChunk = LockFreeList!(VkDeviceMemory).Elem;
alias BufChunk = LockFreeList!(VkBuffer).Elem;

import pukan.vulkan;
import pukan.vulkan.bindings;

class MemoryBufferMappedToCPU : MemoryBuffer
{
    LogicalDevice device;
    void[] cpuBuf; /// CPU-mapped memory buffer

    this(LogicalDevice device, size_t size, VkBufferUsageFlags usageFlags)
    {
        this.device = device;

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
    BufChunk buf;
    alias this = buf;

    this(LogicalDevice device, ref VkBufferCreateInfo createInfo, in VkMemoryPropertyFlags propFlags)
    {
        buf = device.createBuffer(createInfo);

        VkMemoryRequirements memRequirements;
        vkGetBufferMemoryRequirements(device.device, buf, &memRequirements);

        super(device, memRequirements, propFlags);

        vkBindBufferMemory(device, buf, deviceMemory, 0 /*memoryOffset*/).vkCheck;
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
    MemChunk deviceMemory;

    this(LogicalDevice device, in VkMemoryRequirements memRequirements, in VkMemoryPropertyFlags propFlags)
    {
        VkMemoryAllocateInfo allocInfo = {
            sType: VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            allocationSize: memRequirements.size,
            memoryTypeIndex: device.physicalDevice.findMemoryType(memRequirements.memoryTypeBits, propFlags),
        };

        deviceMemory = device.allocateDeviceMemory(allocInfo);
        device.addDeviceMemory(allocInfo.allocationSize, propFlags);
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

        VkBufferCreateInfo dstBufInfo = {
            sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            size: cpuBuffer.cpuBuf.length,
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
    auto cpuBuf() const => cpuBuffer.cpuBuf;
    uint length() const => cast(uint) cpuBuffer.cpuBuf.length;

    void recordUpload(VkCommandBuffer buf)
    {
        gpuBuffer.recordCopyBuffer(buf, cpuBuffer.buf, gpuBuffer.buf, cpuBuf.length);
        device.addUploadedBytes(cpuBuf.length);
    }
}
