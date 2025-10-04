module pukan.vulkan.physical_device;

import pukan.exceptions;
import pukan.vulkan.bindings;
import pukan.vulkan.core: Instance;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.helpers;
import pukan: toPrettyString;

///
class PhysicalDevice
{
    package Instance instance;
    package VkPhysicalDevice physicalDevice;

    ///
    this(Instance inst, VkPhysicalDevice dev)
    {
        instance = inst;
        physicalDevice = dev;
    }

    uint findMemoryType(uint memoryTypeBitFilter, VkMemoryPropertyFlags properties)
    {
        VkPhysicalDeviceMemoryProperties memProperties;
        vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memProperties);

        for(uint i = 0; i < memProperties.memoryTypeCount; i++)
        {
            if ((memoryTypeBitFilter & (1 << i)) && (memProperties.memoryTypes[i].propertyFlags & properties) == properties)
                return i;
        }

        throw new PukanException("failed to find suitable memory type");
    }

    void printDevice()
    {
        //TODO: ref
        auto d = physicalDevice;

        VkPhysicalDeviceProperties props;
        vkGetPhysicalDeviceProperties(d, &props);

        VkPhysicalDeviceProperties2 props2 = {
            sType: VkStructureType.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
        };
        vkGetPhysicalDeviceProperties2(d, &props2);

        VkPhysicalDeviceMemoryProperties mem;
        vkGetPhysicalDeviceMemoryProperties(d, &mem);

        VkPhysicalDeviceFeatures features;
        vkGetPhysicalDeviceFeatures(d, &features);

        Instance.log_info("Properties:");
        Instance.log_info(props.toPrettyString);
        Instance.log_info("Properties 2:");
        Instance.log_info(props2);
        Instance.log_info("Memory:");
        Instance.log_info(mem.toPrettyString);
        Instance.log_info("Features:");
        Instance.log_info(features.toPrettyString);
    }

    // TODO: empty args list?!
    /// Returns: family indices
    auto findSuitableQueueFamilies()
    {
        auto qFamilyProps = getArrayFrom!vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice);
        size_t[] apprIndices;

        foreach(i, qfp; qFamilyProps)
        {
            if (qfp.queueFlags & VK_QUEUE_GRAPHICS_BIT)
               apprIndices ~= i;
        }

        return apprIndices;
    }

    ///
    LogicalDevice createLogicalDevice(const(char*)[] extension_list)
    {
        return new LogicalDevice(instance, physicalDevice, extension_list);
    }
}
