module pukan.vulkan.queue;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;

class Queue
{
    private VkQueue queue;
    private Fence sync;

    this(LogicalDevice dev)
    {
        queue = dev.getQueue();
        sync = dev.create!Fence;
    }

    void syncSubmit(ref VkSubmitInfo submitInfo)
    {
        sync.wait();
        sync.reset();
        vkQueueSubmit(queue, 1, &submitInfo, sync).vkCheck;
    }
}
