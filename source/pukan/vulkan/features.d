module pukan.vulkan.features;

import pukan.exceptions: PukanVulkanException;
import pukan.vulkan.bindings;
import std.conv: to;

/// Device feature tag, generated from a VkPhysicalDeviceFeatures field name
struct Feature(string field)
{
    enum isSupported = __traits(hasMember, VkPhysicalDeviceFeatures, field) &&
        is(typeof(__traits(getMember, VkPhysicalDeviceFeatures, field)) == VkBool32);

    static assert(isSupported, "unknown Vulkan feature: " ~ field);

    enum string name = field;
}

/// Throws if the feature is not supported by the device and enables it otherwise
void requireFeature(F)(ref VkPhysicalDeviceFeatures supported, ref VkPhysicalDeviceFeatures enabled)
{
    if(__traits(getMember, supported, F.name) != VK_TRUE)
        throw new PukanVulkanException("Vulkan feature is not supported: " ~ F.name);

    __traits(getMember, enabled, F.name) = VK_TRUE;
}

/// Device limit tag with the minimum acceptable value
struct Limit(string name, uint minimum)
{
    enum isSupported = __traits(hasMember, VkPhysicalDeviceLimits, name) &&
        is(typeof(__traits(getMember, VkPhysicalDeviceLimits, name)) == uint);

    static assert(isSupported, "unknown uint Vulkan limit: " ~ name);

    enum string field = name;
    enum uint min = minimum;
}

/// Throws when the device limit is below the required minimum
void requireLimit(L)(ref const VkPhysicalDeviceLimits limits)
{
    const value = __traits(getMember, limits, L.field);

    if(value < L.min)
        throw new PukanVulkanException("Vulkan limit " ~ L.field ~ " is " ~ value.to!string ~ ", required at least " ~ L.min.to!string);
}

//TODO: support features from the VkPhysicalDeviceFeatures2 chain structs
//TODO: support array limits, for example maxComputeWorkGroupSize

unittest
{
    alias Anisotropy = Feature!"samplerAnisotropy";
    alias Invocations = Limit!("maxComputeWorkGroupInvocations", 256);

    static assert(Anisotropy.name == "samplerAnisotropy");
    static assert(Invocations.field == "maxComputeWorkGroupInvocations");
    static assert(Invocations.min == 256);
    static assert(!__traits(compiles, Feature!"notAFeature"));
    static assert(!__traits(compiles, Limit!("notALimit", 1)));
}
