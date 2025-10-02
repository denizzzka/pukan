module pukan.vulkan.logical_device;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.exceptions;
import log = std.logger;
import std.exception: enforce;
import std.string: toStringz;

class LogicalDevice
{
    Backend backend; // TODO: rewrite to "Instance instance"
    VkDevice device;
    alias this = device;

    const uint familyIdx;

    package this(Backend b, VkPhysicalDevice physicalDevice, const(char*)[] extension_list)
    {
        backend = b;

        VkPhysicalDeviceFeatures supportedFeatures;
        vkGetPhysicalDeviceFeatures(physicalDevice, &supportedFeatures);

        const fqIdxs = b.findSuitableQueueFamilies();
        enforce(fqIdxs.length > 0);
        familyIdx = cast(uint) fqIdxs[0];

        immutable float queuePriority = 1.0f;

        VkDeviceQueueCreateInfo queueCreateInfo = {
            sType: VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex: familyIdx,
            queueCount: 1,
            pQueuePriorities: &queuePriority,
        };

        enforce!PukanException(supportedFeatures.samplerAnisotropy == true);
        VkPhysicalDeviceFeatures deviceFeatures = {
            samplerAnisotropy: VK_TRUE,
        };

        VkPhysicalDeviceShaderObjectFeaturesEXT shaderObjectFeatures = {
            sType: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
            shaderObject: VK_TRUE,
        };

        VkDeviceCreateInfo createInfo = {
            sType: VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            queueCreateInfoCount: 1,
            pQueueCreateInfos: &queueCreateInfo,
            pEnabledFeatures: &deviceFeatures,
            ppEnabledExtensionNames: extension_list.ptr,
            enabledExtensionCount: cast(uint) extension_list.length,
            pNext: &shaderObjectFeatures,
        };

        vkCreateDevice(physicalDevice, &createInfo, b.allocator, &device).vkCheck;
    }

    ~this()
    {
        if(device)
            vkDestroyDevice(device, backend.allocator);
    }

    //TODO: remove
    auto getQueue()
    {
        return getQueue(0);
    }

    ///
    auto getQueue(uint queueIdx)
    {
        VkQueue ret;
        vkGetDeviceQueue(device, familyIdx, queueIdx, &ret);

        return ret;
    }

    ///
    auto createSyncQueue()
    {
        import pukan.vulkan.queue: Queue;

        return new Queue(this);
    }

    auto create(alias ClassType, A...)(A a)
    {
        return new ClassType(this, a);
    }

    auto createSemaphore()
    {
        return create!Semaphore;
    }

    auto createFence()
    {
        return create!Fence;
    }

    auto createCommandPool()
    {
        return new CommandPool(this, familyIdx);
    }
}

class Semaphore
{
    ubyte[70000] FIXME_druntime_issue_REMOVE_ME;
    LogicalDevice device;
    VkSemaphore semaphore;
    alias this = semaphore;

    this(LogicalDevice dev)
    {
        device = dev;

        VkSemaphoreCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        vkCreateSemaphore(device.device, &cinf, device.backend.allocator, &semaphore).vkCheck;
    }

    ~this()
    {
        if(semaphore)
            vkDestroySemaphore(device.device, semaphore, device.backend.allocator);
    }
}

class Fence
{
    //~ ubyte[70000] FIXME_druntime_issue_REMOVE_ME;
    LogicalDevice device;
    VkFence fence;
    alias this = fence;

    this(LogicalDevice dev)
    {
        device = dev;

        VkFenceCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            flags: VK_FENCE_CREATE_SIGNALED_BIT,
        };

        vkCreateFence(device.device, &cinf, device.backend.allocator, &fence).vkCheck;
    }

    ~this()
    {
        if(fence)
            vkDestroyFence(device.device, fence, device.backend.allocator);
    }

    void wait()
    {
        vkWaitForFences(device, 1, &fence, VK_TRUE, uint.max).vkCheck;
    }

    void reset()
    {
        vkResetFences(device, 1, &fence).vkCheck;
    }
}
