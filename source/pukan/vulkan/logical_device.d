module pukan.vulkan.logical_device;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.physical_device: PhysicalDevice;
import pukan.exceptions;
import log = std.logger;
import std.exception: enforce;
import std.string: toStringz;

class LogicalDevice
{
    PhysicalDevice physicalDevice;
    VkDevice device;
    alias this = device;

    const uint familyIdx;

    package this(PhysicalDevice pd, const(char*)[] extension_list)
    {
        physicalDevice = pd;

        VkPhysicalDeviceFeatures supportedFeatures;
        vkGetPhysicalDeviceFeatures(pd.physicalDevice, &supportedFeatures);

        const fqIdxs = pd.findSuitableQueueFamilies();
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

        debug
        {
            import std.algorithm;
            import std.array;
            import std.conv: to;

            const avail_on_dflt_layer = pd.extensions
                .map!((e) => e.extensionName.ptr.to!string)
                .array;

            const need = extension_list
                .map!((e) => e.to!string)
                .array;

            foreach(e; need)
            {
                if(!avail_on_dflt_layer.canFind(e))
                    Instance.log_info(">>> Necessary extension "~e~" not supported!");
            }
        }

        vkCreateDevice(pd.physicalDevice, &createInfo, alloc, &device).vkCheck;
    }

    ~this()
    {
        if(device)
            vkDestroyDevice(device, alloc);
    }

    auto alloc() => physicalDevice.instance.allocator;

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

        vkCreateSemaphore(device.device, &cinf, device.alloc, &semaphore).vkCheck;
    }

    ~this()
    {
        if(semaphore)
            vkDestroySemaphore(device.device, semaphore, device.alloc);
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

        vkCreateFence(device.device, &cinf, device.alloc, &fence).vkCheck;
    }

    ~this()
    {
        if(fence)
            vkDestroyFence(device.device, fence, device.alloc);
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
