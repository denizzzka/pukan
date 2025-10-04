module pukan.vulkan.physical_device;

import pukan.exceptions;
import pukan.vulkan.bindings;
import pukan.vulkan.core: Instance;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.helpers;
import pukan: toPrettyString;
import std.conv: to;

///
class PhysicalDevice
{
    Instance instance;
    package VkPhysicalDevice physicalDevice;
    /* TODO: "debug" */ private size_t devIdx;

    ///
    this(Instance inst, VkPhysicalDevice dev, size_t idx)
    {
        instance = inst;
        physicalDevice = dev;
        devIdx = idx;
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
        return new LogicalDevice(this, extension_list);
    }

    /**
        When layerName parameter is null, only extensions provided by the
        Vulkan implementation or by implicitly enabled layers are returned.
        When layerName is the name of a layer, the device extensions
        provided by that layer are returned.
    */
    VkExtensionProperties[] extensions(const(char*) layerName = null)
    {
        return getArrayFrom!vkEnumerateDeviceExtensionProperties(physicalDevice, layerName);
    }

    /// Throw exception if extension is not supported
    void checkExtensionSupportedEx(in char* extensionName, string file = __FILE__, size_t line = __LINE__)
    {
        import core.stdc.string: strcmp;

        foreach(e; extensions)
        {
            if(strcmp(&e.extensionName[0], extensionName) == 0)
                return;
        }

        throw new PukanException("Extension "~extensionName.to!string~" is not supported by Vulkan physical device "~devIdx.to!string, file, line);
    }
}
