module pukan.vulkan.queue;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;

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

    // Not same as CommandPool.submit() - blocks on start and don't waits on end
    void syncSubmit(ref VkSubmitInfo submitInfo)
    {
        sync.wait();
        sync.reset();
        device.submitQueue(submitInfo, sync.fence.handle);
    }
}
