module pukan.vulkan.commands;

import pukan.vulkan;
import pukan.vulkan.bindings;

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

    VkCommandPool commandPool;

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

        vkCreateCommandPool(device.device, &cinf, device.alloc, &commandPool).vkCheck;
    }

    ~this()
    {
        if(commandPool)
            vkDestroyCommandPool(device.device, commandPool, device.alloc);
    }

    VkCommandBuffer[] allocateBuffers(uint count)
    in(count > 0)
    {
        VkCommandBuffer[] ret;
        ret.length = count;

        auto allocInfo = defaultBufferAllocateInfo;
        allocInfo.commandPool = commandPool;
        allocInfo.commandBufferCount = count;

        vkAllocateCommandBuffers(device.device, &allocInfo, &ret[0]).vkCheck;

        return ret;
    }

    void recordCommands(VkCommandBufferBeginInfo beginInfo, VkCommandBuffer buf, void delegate(VkCommandBuffer) dg)
    {
        vkBeginCommandBuffer(buf, &beginInfo).vkCheck;
        dg(buf);
        vkEndCommandBuffer(buf).vkCheck("failed to record command buffer");
    }

    void recordOneTime(VkCommandBuffer buf, void delegate(VkCommandBuffer) dg)
    {
        auto cinf = defaultOneTimeBufferBeginInfo;
        recordCommands(cinf, buf, dg);
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

        auto fence = device.createFence;
        scope(exit) destroy(fence);

        vkResetFences(device, 1, &fence.fence).vkCheck;
        vkQueueSubmit(device.getQueue(), 1, &submitInfo, fence).vkCheck;
        vkWaitForFences(device.device, 1, &fence.fence, VK_TRUE, uint.max).vkCheck;
    }
}
