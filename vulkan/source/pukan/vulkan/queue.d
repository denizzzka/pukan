module pukan.vulkan.queue;

import pukan.vulkan.bindings;
import pukan.vulkan.helpers;
import pukan.vulkan.logical_device: Fence, LogicalDevice;

class Queue
{
    private LogicalDevice device;
    private VkQueue queue;
    private Fence sync;

    this(LogicalDevice dev)
    {
        device = dev;
        queue = dev.getQueue();
        sync = dev.create!Fence;
    }

    ~this()
    {
        if(sync)
            destroy(sync);
    }

    // Not same as CommandPool.submit() - blocks on start and don't waits on end
    void syncSubmit(ref VkSubmitInfo submitInfo)
    {
        sync.wait();
        sync.reset();
        device.submitQueue(submitInfo, sync.fence.vk);
    }
}
