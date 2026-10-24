module pukan.vulkan.requirements;

import pukan.vulkan.api_version: VulkanVersion, requiredApiVersionEncoded;
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

    /// Returns false and a reason when the requirement is not met
    static bool isSatisfied(ref DeviceContext ctx, out string reason)
    {
        static if(kind == Kind.number)
        {
            static if(__traits(hasMember, VkPhysicalDeviceProperties, name))
                const value = __traits(getMember, ctx.properties, name);
            else
                const value = __traits(getMember, ctx.properties.limits, name);

            if(value < minimum)
            {
                reason = name ~ " is " ~ value.to!string ~ ", required at least " ~ minimum.to!string;
                return false;
            }
        }
        else static if(kind == Kind.feature)
        {
            if(__traits(getMember, ctx.supported, name) != VK_TRUE)
            {
                reason = "feature is not supported: " ~ name;
                return false;
            }
        }
        else static if(kind == Kind.extension)
        {
            if(!ctx.supportsExtension(name))
            {
                reason = "extension is not supported: " ~ name;
                return false;
            }
        }

        return true;
    }

    /// Enables the feature or extension; numeric values have nothing to request
    static void request(ref DeviceContext ctx)
    {
        static if(kind == Kind.feature)
            __traits(getMember, ctx.enabled, name) = VK_TRUE;
        else static if(kind == Kind.extension)
            ctx.enabledExtensions ~= name.ptr;
    }

    /// Returns false and a reason when the requirement is not met by the instance
    static bool isSatisfied(Ctx)(ref Ctx ctx, out string reason) if(is(Ctx == InstanceContext))
    {
        static if(kind == Kind.number && name == "apiVersion")
        {
            const required = VulkanVersion.fromUint(cast(uint) minimum);

            if(ctx.loaderVersion < required)
            {
                reason = name ~ " is " ~ ctx.loaderVersion.toString ~ ", required at least " ~ required.toString;
                return false;
            }

            return true;
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
alias ApiVersionRequirement = Requirement!("apiVersion", requiredApiVersionEncoded);

/// Returns true when every requirement is satisfied, otherwise fills the reason
bool requirementsSatisfied(Reqs...)(ref DeviceContext ctx, out string reason)
{
    static foreach(R; NoDuplicates!Reqs)
        if(!R.isSatisfied(ctx, reason))
            return false;

    return true;
}

/// Enables every requested feature and extension
void requestRequirements(Reqs...)(ref DeviceContext ctx)
{
    static foreach(R; NoDuplicates!Reqs)
        R.request(ctx);
}

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

    string reason;
    assert(!ApiVersionRequirement.isSatisfied(instance, reason));
    assert(reason.length > 0);

    instance.loaderVersion = VulkanVersion(1, 3);
    assert(ApiVersionRequirement.isSatisfied(instance, reason));
}
