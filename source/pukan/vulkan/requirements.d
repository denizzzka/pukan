module pukan.vulkan.requirements;

import pukan.exceptions: PukanVulkanException;
import pukan.vulkan.api_version: VulkanVersion, requiredApiVersion;
import pukan.vulkan.bindings;
import core.stdc.string: strcmp;
import std.conv: to;
import std.meta: AliasSeq, NoDuplicates, staticMap;

private enum Kind { number, feature, extension }

private template requirementKind(string name)
{
    static if(name.length > 3 && name[0 .. 3] == "VK_")
        enum requirementKind = Kind.extension;
    else static if(__traits(hasMember, VkPhysicalDeviceFeatures, name) &&
        is(typeof(__traits(getMember, VkPhysicalDeviceFeatures, name)) == VkBool32))
        enum requirementKind = Kind.feature;
    else static if(__traits(hasMember, VkPhysicalDeviceProperties, name) &&
        is(typeof(__traits(getMember, VkPhysicalDeviceProperties, name)) == uint))
        enum requirementKind = Kind.number;
    else static if(__traits(hasMember, VkPhysicalDeviceLimits, name) &&
        is(typeof(__traits(getMember, VkPhysicalDeviceLimits, name)) == uint))
        enum requirementKind = Kind.number;
    else
        static assert(false, "unknown Vulkan requirement: " ~ name);
}

/// Device snapshot the requirements are checked against
struct DeviceContext
{
    VkPhysicalDeviceProperties properties;
    VkPhysicalDeviceFeatures supported;
    VkPhysicalDeviceFeatures enabled;
    VkExtensionProperties[] supportedExtensions;
    const(char)*[] enabledExtensions;

    bool supportsExtension(string name) const
    {
        foreach(e; supportedExtensions)
            if(strcmp(&e.extensionName[0], name.ptr) == 0)
                return true;

        return false;
    }
}

/// Instance snapshot the requirements are checked against
struct InstanceContext
{
    VulkanVersion loaderVersion;
}

/// Device requirement: a numeric property, a feature or an extension
struct Requirement(string name, ulong minimum = 0)
{
    private enum kind = requirementKind!name;

    static if(kind == Kind.feature)
        static assert(minimum == 0, "feature requirement takes no minimum: " ~ name);
    else static if(kind == Kind.extension)
        static assert(minimum == 0, "extension requirement takes no minimum: " ~ name);

    /// Throws when the requirement is not met, enables features and extensions
    static void check(ref DeviceContext ctx)
    {
        static if(kind == Kind.number)
        {
            static if(__traits(hasMember, VkPhysicalDeviceProperties, name))
                const value = __traits(getMember, ctx.properties, name);
            else
                const value = __traits(getMember, ctx.properties.limits, name);

            if(value < minimum)
                throw new PukanVulkanException("Vulkan requirement " ~ name ~ " is " ~ value.to!string ~ ", required at least " ~ minimum.to!string);
        }
        else static if(kind == Kind.feature)
        {
            if(__traits(getMember, ctx.supported, name) != VK_TRUE)
                throw new PukanVulkanException("Vulkan feature is not supported: " ~ name);

            __traits(getMember, ctx.enabled, name) = VK_TRUE;
        }
        else static if(kind == Kind.extension)
        {
            if(!ctx.supportsExtension(name))
                throw new PukanVulkanException("Vulkan extension is not supported: " ~ name);

            ctx.enabledExtensions ~= name.ptr;
        }
    }

    /// Throws when the requirement is not met by the instance
    static void check(Ctx)(ref Ctx ctx) if(is(Ctx == InstanceContext))
    {
        static if(kind == Kind.number && name == "apiVersion")
        {
            const required = VulkanVersion.fromUint(cast(uint) minimum);

            if(ctx.loaderVersion < required)
                throw new PukanVulkanException("Vulkan requirement " ~ name ~ " is " ~ ctx.loaderVersion.toString ~ ", required at least " ~ required.toString);
        }
        else
            static assert(false, name ~ " is not an instance requirement");
    }
}

private template moduleRequirements(M)
{
    static if(__traits(hasMember, M, "requirements"))
        alias moduleRequirements = M.requirements;
    else
        alias moduleRequirements = AliasSeq!();
}

/// Union of the requirements declared by the given subsystems, without duplicates
template Requirements(Modules...)
{
    alias Requirements = NoDuplicates!(staticMap!(moduleRequirements, Modules));
}

/// Baseline requirement every instance and device must satisfy
alias ApiVersionRequirement = Requirement!("apiVersion", requiredApiVersion.toUint());

unittest
{
    static assert(Requirement!"samplerAnisotropy".kind == Kind.feature);
    static assert(Requirement!("maxComputeWorkGroupInvocations", 256).kind == Kind.number);
    static assert(Requirement!(VK_KHR_SWAPCHAIN_EXTENSION_NAME).kind == Kind.extension);
    static assert(Requirement!("apiVersion", VulkanVersion(1, 3).toUint()).kind == Kind.number);
    static assert(!__traits(compiles, Requirement!"notARequirement"));

    static struct A { alias requirements = AliasSeq!(Requirement!"samplerAnisotropy"); }
    static struct B { alias requirements = AliasSeq!(Requirement!"samplerAnisotropy"); }
    static assert(Requirements!(A, B).length == 1);

    InstanceContext instance;
    instance.loaderVersion = VulkanVersion(1, 2);

    bool thrown;
    try
        ApiVersionRequirement.check(instance);
    catch(PukanVulkanException)
        thrown = true;

    assert(thrown);
}
