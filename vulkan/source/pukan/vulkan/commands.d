module pukan.vulkan.commands;

import pukan.vulkan.bindings;
import pukan.vulkan.helpers: vkCheck;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.resources.release: ReleaseQueue;
import pukan.vulkan.resources.vkobj: VkObj;

/**
Command pools are externally synchronized, meaning that a command pool
must not be used concurrently in multiple threads. That includes use
via recording commands on any command buffers allocated from the pool,
as well as operations that allocate, free, and reset command buffers or
the pool itself.
*/
class CommandPool
{
    LogicalDevice device;

    VkObj!VkCommandPool commandPool;

    enum VkCommandPoolCreateInfo defaultPoolCreateInfo = {
        sType: VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        flags: VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
    };

    enum VkCommandBufferAllocateInfo defaultBufferAllocateInfo = {
        sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        level: VK_COMMAND_BUFFER_LEVEL_PRIMARY,
    };

    enum VkCommandBufferBeginInfo defaultBufferBeginInfo = {
        sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    };

    enum VkCommandBufferBeginInfo defaultOneTimeBufferBeginInfo = {
        sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        flags: VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };

    this(LogicalDevice dev, uint queueFamilyIndex)
    {
        device = dev;

        auto cinf = defaultPoolCreateInfo;
        cinf.queueFamilyIndex = queueFamilyIndex;

        commandPool = VkObj!VkCommandPool(device.releaseQueue, cinf);
    }

    VkCommandBuffer[] allocateBuffers(uint count)
    in(count > 0)
    {
        VkCommandBuffer[] ret;
        ret.length = count;

        auto allocInfo = defaultBufferAllocateInfo;
        allocInfo.commandPool = commandPool.vk;
        allocInfo.commandBufferCount = count;

        vkAllocateCommandBuffers(device.device, &allocInfo, &ret[0]).vkCheck;

        return ret;
    }



    void freeBuffers(VkCommandBuffer[] buffs)
    {
        vkFreeCommandBuffers(device, commandPool.vk, cast(uint) buffs.length, &buffs[0]);
    }

    void recordOneTimeAndSubmit(VkCommandBuffer buf, void delegate(VkCommandBuffer) dg)
    {
        recordOneTime(buf, dg);
        submitBuffers([buf]);
    }

    void submitBuffers(VkCommandBuffer[] commandBuffers)
    {
        VkSubmitInfo submitInfo = {
            sType: VK_STRUCTURE_TYPE_SUBMIT_INFO,
            commandBufferCount: cast(uint) commandBuffers.length,
            pCommandBuffers: commandBuffers.ptr,
        };

        submit(submitInfo);
    }

    void submit(ref VkSubmitInfo submitInfo)
    {
        auto fence = device.createFence;
        scope(exit) destroy(fence);

        vkResetFences(device, 1, fence.fence.vkPtr).vkCheck;
        device.submitQueue(submitInfo, fence.fence.vk);
        vkWaitForFences(device.device, 1, fence.fence.vkPtr, VK_TRUE, uint.max).vkCheck;
    }
}

/// Command buffers of one frame, freed once the frames in flight pass
final class CommandBuffers
{
    private ReleaseQueue queue;
    private VkCommandPool pool;
    private VkCommandBuffer[] buffers;

    this(ReleaseQueue queue, VkCommandPool pool, VkCommandBuffer[] buffers)
    {
        this.queue = queue;
        this.pool = pool;
        this.buffers = buffers;
    }

    ref VkCommandBuffer opIndex(size_t i) => buffers[i];
    size_t length() const => buffers.length;

    ~this()
    {
        if(queue is null || queue.isClosed || buffers.length == 0)
            return;

        vkFreeCommandBuffers(queue.device, pool, cast(uint) buffers.length, buffers.ptr);
    }
}

void recordCommands(VkCommandBufferBeginInfo beginInfo, VkCommandBuffer buf, void delegate(VkCommandBuffer) dg)
{
    vkBeginCommandBuffer(buf, &beginInfo).vkCheck;
    dg(buf);
    endCommandBuffer(buf);
}

void recordOneTime(VkCommandBuffer buf, void delegate(VkCommandBuffer) dg)
{
    auto cinf = CommandPool.defaultOneTimeBufferBeginInfo;
    recordCommands(cinf, buf, dg);
}

void beginOneTimeCommandBuffer(VkCommandBuffer buf)
{
    auto cinf = CommandPool.defaultOneTimeBufferBeginInfo;
    vkBeginCommandBuffer(buf, &cinf).vkCheck;
}

void endCommandBuffer(VkCommandBuffer buf)
{
    vkEndCommandBuffer(buf).vkCheck("failed to record command buffer");
}
