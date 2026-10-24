module pukan.vulkan.api_version;

import pukan.exceptions: PukanVulkanExceptionWithCode;
import pukan.vulkan.bindings;

/// Vulkan API version, ordered by major, minor and patch
struct VulkanVersion
{
    uint major;
    uint minor;
    uint patch;
    uint variant;

    static VulkanVersion fromUint(uint encoded) pure nothrow @nogc
    {
        return VulkanVersion(
            (encoded >> 22) & 0x7F,
            (encoded >> 12) & 0x3FF,
            encoded & 0xFFF,
            encoded >> 29,
        );
    }

    uint toUint() const pure nothrow @nogc
    {
        return (variant << 29) | (major << 22) | (minor << 12) | patch;
    }

    int opCmp(const VulkanVersion rhs) const pure nothrow @nogc
    {
        if(major != rhs.major)
            return major < rhs.major ? -1 : 1;
        if(minor != rhs.minor)
            return minor < rhs.minor ? -1 : 1;
        if(patch != rhs.patch)
            return patch < rhs.patch ? -1 : 1;

        return 0;
    }

    string toString() const
    {
        import std.format: format;

        return format!"%d.%d.%d"(major, minor, patch);
    }
}

/// Version supported by the Vulkan loader, 1.0 if the loader predates Vulkan 1.1
VulkanVersion loaderVersion()
{
    const proc = cast(PFN_vkEnumerateInstanceVersion) vkGetInstanceProcAddr(null, "vkEnumerateInstanceVersion");

    if(proc is null)
        return VulkanVersion(1, 0);

    uint encoded;
    const ret = proc(&encoded);

    if(ret != VK_SUCCESS)
        throw new PukanVulkanExceptionWithCode(ret, "failed to query the Vulkan loader version");

    return VulkanVersion.fromUint(encoded);
}

/// Version supported by the physical device
VulkanVersion physicalDeviceVersion(VkPhysicalDevice device)
{
    //TODO: vkGetPhysicalDeviceProperties must not be called separately for each checked property
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(device, &props);

    return VulkanVersion.fromUint(props.apiVersion);
}

unittest
{
    static assert(VulkanVersion(1, 3) > VulkanVersion(1, 2));
    static assert(VulkanVersion(1, 3, 1) > VulkanVersion(1, 3, 0));

    static assert(VulkanVersion.fromUint(VulkanVersion(1, 3, 0).toUint()) == VulkanVersion(1, 3, 0));
    static assert(VulkanVersion(1, 3, 0).toUint() == ((1 << 22) | (3 << 12)));
}
