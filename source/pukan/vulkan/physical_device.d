module pukan.vulkan.physical_device;

import pukan.exceptions;
import pukan.vulkan.bindings;
import pukan.vulkan.core: Instance;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.helpers;
import pukan.vulkan.requirements;
import pukan: toPrettyString;
import std.meta: AliasSeq;

///
class PhysicalDevice
{
    Instance instance;
    package VkPhysicalDevice physicalDevice;
    /// Queried once, all property checks read this snapshot
    // TODO: caching is not needed, query the properties at the use site
    immutable VkPhysicalDeviceProperties properties;

    ///
    this(Instance inst, VkPhysicalDevice dev)
    {
        instance = inst;
        physicalDevice = dev;

        VkPhysicalDeviceProperties props;
        vkGetPhysicalDeviceProperties(dev, &props);
        properties = props;
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

        throw new PukanVulkanException("failed to find suitable memory type");
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
    /// Returns: family indices satisfying the required flags
    auto findSuitableQueueFamilies(VkQueueFlags required = VK_QUEUE_GRAPHICS_BIT)
    {
        auto qFamilyProps = getArrayFrom!vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice);
        size_t[] apprIndices;

        foreach(i, qfp; qFamilyProps)
        {
            if((qfp.queueFlags & required) == required)
               apprIndices ~= i;
        }

        return apprIndices;
    }

    /// Snapshots properties, supported features and extensions
    package bool createLogicalDeviceContext(Reqs...)(const(char)*[] extension_list, out DeviceContext ctx, out string reason)
    {
        ctx.device = physicalDevice;
        ctx.properties = properties;
        ctx.queueFamilies = getArrayFrom!vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice);
        ctx.supportedExtensions = extensions();
        ctx.enabledExtensions = extension_list.dup;

        return queryDeviceFeatures!Reqs(physicalDevice, ctx, reason);
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

    // TODO: may be removed if GPU menu moves to SelectedDevice
    /// Creates logical device from a pre-prepared context
    package LogicalDevice createLogicalDeviceFromContext(Reqs...)(DeviceContext ctx)
    {
        FeatureChain chain;
        fillFeatureChain!Reqs(chain);

        return new LogicalDevice(this, ctx.enabledExtensions, ctx.enabled, ctx.enabledChainMask, chain, QueueFlagsFor!Reqs);
    }
}

/// A physical device that was checked against requirements; the list is bound to the type
struct SelectedDevice(Reqs...)
{
    package PhysicalDevice physicalDevice;
    package DeviceContext context;
    package this(PhysicalDevice pd, DeviceContext ctx)
    {
        physicalDevice = pd;
        context = ctx;
    }

    /// Creates the logical device using the requirements that were used for selection
    LogicalDevice createLogicalDevice(Modules...)()
    {
        auto ctx = context;
        alias optional = OptionalRequirementsWithout!Reqs.Of!(OptionalRequirementsFor!(LogicalDevice, Modules));
        requestOptionalRequirements!optional(ctx);
        return physicalDevice.createLogicalDeviceFromContext!Reqs(ctx);
    }

    /// Access to the physical device for queues/memory etc.
    PhysicalDevice device()
    {
        return physicalDevice;
    }
}
