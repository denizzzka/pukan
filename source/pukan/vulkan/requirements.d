module pukan.vulkan.requirements;

import pukan.vulkan.api_version: VulkanVersion, requiredApiVersionEncoded;
import pukan.vulkan.bindings;
import core.stdc.string: strcmp;
import std.conv: to;
import std.meta: AliasSeq, NoDuplicates, staticMap;

private enum Kind { number, feature, extension }

private template isNumberType(T)
{
    enum isNumberType =
        is(T == uint) || is(T == int) || is(T == ulong) || is(T == long) ||
        is(T == float) || is(T == double);
}

/// Declare optional requirements for an entity
template getOptionalRequirements(Reqs...)
{
    private import std.meta: AliasSeq;
    alias getOptionalRequirements = AliasSeq!Reqs;
}

private template requirementKind(string name)
{
    static if(name.length > 3 && name[0 .. 3] == "VK_")
        enum requirementKind = Kind.extension;
    else static if(__traits(hasMember, VkPhysicalDeviceFeatures, name) &&
        is(typeof(__traits(getMember, VkPhysicalDeviceFeatures, name)) == VkBool32))
        enum requirementKind = Kind.feature;
    else static if(__traits(hasMember, VkPhysicalDeviceProperties, name) &&
        isNumberType!(typeof(__traits(getMember, VkPhysicalDeviceProperties, name))))
        enum requirementKind = Kind.number;
    else static if(__traits(hasMember, VkPhysicalDeviceLimits, name) &&
        isNumberType!(typeof(__traits(getMember, VkPhysicalDeviceLimits, name))))
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

    bool hasEnabledExtension(string name) const
    {
        import core.stdc.string: strcmp;

        foreach(e; enabledExtensions)
            if(strcmp(e, name.ptr) == 0)
                return true;

        return false;
    }
}

/// Instance snapshot the requirements are checked against
struct InstanceContext
{
    VulkanVersion loaderVersion;
    const(char)*[] enabledExtensions;

    bool hasEnabledExtension(string name) const
    {
        import core.stdc.string: strcmp;

        foreach(e; enabledExtensions)
            if(strcmp(e, name.ptr) == 0)
                return true;

        return false;
    }
}

/// Device requirement: a numeric property, a feature or an extension
/// Features and extensions have no minimum, so it only matters for numbers
// TODO: take the name from a symbol and reject string literals with static assert
struct Requirement(string name, ulong minimum = 0)
{
    package enum kind = requirementKind!name;

    /// True when this is a device/instance extension
    enum bool isExtension = kind == Kind.extension;
    /// True when this is a VkBool32 feature
    enum bool isFeature = kind == Kind.feature;

    /// Name used in diagnostics
    enum string requirementName = name;

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

    /// Returns false and a reason when the requirement is not enabled
    static bool isEnabled(ref const DeviceContext ctx, out string reason)
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
            if(__traits(getMember, ctx.enabled, name) != VK_TRUE)
            {
                reason = "feature is not enabled: " ~ name;
                return false;
            }
        }
        else static if(kind == Kind.extension)
        {
            if(!ctx.hasEnabledExtension(name))
            {
                reason = "extension is not enabled: " ~ name;
                return false;
            }
        }

        return true;
    }

    /// Returns false and a reason when the requirement is not enabled by the instance
    static bool isEnabled(Ctx)(ref const Ctx ctx, out string reason) if(is(Ctx == InstanceContext))
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
        else static if(kind == Kind.extension)
        {
            if(!ctx.hasEnabledExtension(name))
            {
                reason = "extension is not enabled: " ~ name;
                return false;
            }

            return true;
        }
        else
            static assert(false, name ~ " is not an instance requirement");
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

/// Requirement for a Vulkan struct field, named after the field symbol
template RequirementOf(alias field, ulong minimum = 0)
{
    alias RequirementOf = Requirement!(__traits(identifier, field), minimum);
}

/// True when T is present in the list
template contains(T, List...)
{
    static if(List.length == 0)
        enum contains = false;
    else static if(is(List[0] == T))
        enum contains = true;
    else
        enum contains = contains!(T, List[1 .. $]);
}

private template moduleRequirements(M)
{
    static if(__traits(hasMember, M, "requirements"))
        alias moduleRequirements = __traits(getMember, M, "requirements");
    else
        alias moduleRequirements = AliasSeq!();
}

/// Union of the requirements declared by the given subsystems, without duplicates
template Requirements(Modules...)
{
    alias Requirements = NoDuplicates!(staticMap!(moduleRequirements, Modules));
}

private template moduleOptionalRequirements(M)
{
    static if(__traits(hasMember, M, "optionalRequirements"))
        alias moduleOptionalRequirements = __traits(getMember, M, "optionalRequirements");
    else
        alias moduleOptionalRequirements = AliasSeq!();
}

/// Union of optional requirements declared by the given entities/modules, without duplicates
template OptionalRequirementsOf(Modules...)
{
    alias OptionalRequirementsOf = NoDuplicates!(staticMap!(moduleOptionalRequirements, Modules));
}

/// Instantiates an entity template with Backend; plain types are kept as is
private template resolveEntity(alias M, Backend)
{
    static if(__traits(compiles, M!Backend))
        alias resolveEntity = M!Backend;
    else static if(__traits(isTemplate, M))
        static assert(false, "cannot instantiate this entity template with " ~ Backend.stringof);
    else
        alias resolveEntity = M;
}

private template moduleResolvedOptionalRequirements(Backend, alias M)
{
    alias moduleResolvedOptionalRequirements =
        moduleOptionalRequirements!(resolveEntity!(M, Backend));
}

/// Union of optional requirements of entities resolved against Backend, without duplicates
template OptionalRequirementsFor(Backend, Modules...)
{
    private template moduleOptional(alias M)
    {
        alias moduleOptional = moduleResolvedOptionalRequirements!(Backend, M);
    }

    alias OptionalRequirementsFor = NoDuplicates!(staticMap!(moduleOptional, Modules));
}

private template moduleResolvedRequirements(Backend, alias M)
{
    static if(__traits(hasMember, resolveEntity!(M, Backend), "requirements"))
        alias moduleResolvedRequirements = __traits(getMember, resolveEntity!(M, Backend), "requirements");
    else
        alias moduleResolvedRequirements = AliasSeq!();
}

/// Union of required requirements of entities resolved against Backend, without duplicates
template RequirementsFor(Backend, Modules...)
{
    private template moduleRequired(alias M)
    {
        alias moduleRequired = moduleResolvedRequirements!(Backend, M);
    }

    alias RequirementsFor = NoDuplicates!(staticMap!(moduleRequired, Modules));
}

/// Names of the extension requirements in Reqs
template extensionNames(Reqs...)
{
    private enum string[] collect()
    {
        string[] names;

        static foreach(R; NoDuplicates!Reqs)
            static if(R.isExtension)
                names ~= R.requirementName;

        return names;
    }

    enum string[] extensionNames = collect();
}

/// Baseline requirement every instance and device must satisfy
alias ApiVersionRequirement = RequirementOf!(VkPhysicalDeviceProperties.apiVersion, requiredApiVersionEncoded);

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

/// Enables optional features and extensions if they are supported, otherwise skips them
void requestOptionalRequirements(Reqs...)(ref DeviceContext ctx)
{
    static foreach(R; NoDuplicates!Reqs)
    {{
        string reason;
        if(R.isSatisfied(ctx, reason))
            R.request(ctx);
    }}
}

/// Returns true when every requirement is enabled, otherwise fills the reason
bool requirementsEnabled(Reqs...)(ref const DeviceContext ctx, out string reason)
{
    static foreach(R; NoDuplicates!Reqs)
        if(!R.isEnabled(ctx, reason))
            return false;

    return true;
}

/// Returns true when every requirement is enabled by the instance, otherwise fills the reason
bool requirementsEnabled(Reqs...)(ref const InstanceContext ctx, out string reason)
{
    static foreach(R; NoDuplicates!Reqs)
        if(!R.isEnabled(ctx, reason))
            return false;

    return true;
}

/// Throws RequirementsNotMetException if any requirement is not enabled
void requireEnabled(Reqs...)(ref const DeviceContext ctx, string entity, string file = __FILE__, size_t line = __LINE__)
{
    import pukan.exceptions: RequirementsNotMetException;

    string[] missing;
    static foreach(R; NoDuplicates!Reqs)
    {{
        string reason;
        if(!R.isEnabled(ctx, reason))
            missing ~= reason;
    }}

    if(missing.length)
        throw new RequirementsNotMetException(entity, missing, file, line);
}

/// Throws RequirementsNotMetException if any requirement is not enabled
void requireEnabled(Reqs...)(ref const InstanceContext ctx, string entity, string file = __FILE__, size_t line = __LINE__)
{
    import pukan.exceptions: RequirementsNotMetException;

    string[] missing;
    static foreach(R; NoDuplicates!Reqs)
    {{
        string reason;
        if(!R.isEnabled(ctx, reason))
            missing ~= reason;
    }}

    if(missing.length)
        throw new RequirementsNotMetException(entity, missing, file, line);
}

unittest
{
    static assert(Requirement!"samplerAnisotropy".kind == Kind.feature);
    static assert(Requirement!("maxComputeWorkGroupInvocations", 256).kind == Kind.number);
    static assert(Requirement!(VK_KHR_SWAPCHAIN_EXTENSION_NAME).kind == Kind.extension);
    static assert(Requirement!("apiVersion", VulkanVersion(1, 3).toUint()).kind == Kind.number);
    static assert(is(RequirementOf!(VkPhysicalDeviceLimits.maxComputeWorkGroupInvocations, 256) ==
        Requirement!("maxComputeWorkGroupInvocations", 256)));
    static assert(!__traits(compiles, Requirement!"notARequirement"));

    static struct A { private alias requirements = AliasSeq!(Requirement!"samplerAnisotropy"); }
    static struct B { private alias requirements = AliasSeq!(Requirement!"samplerAnisotropy"); }
    static assert(Requirements!(A, B).length == 1);

    static assert(contains!(int, int, float));
    static assert(!contains!(double, int, float));

    InstanceContext instance;
    instance.loaderVersion = VulkanVersion(1, 2);

    string reason;
    assert(!ApiVersionRequirement.isSatisfied(instance, reason));
    assert(reason.length > 0);

    instance.loaderVersion = VulkanVersion(1, 3);
    assert(ApiVersionRequirement.isSatisfied(instance, reason));

    import std.exception: assertThrown;
    import pukan.exceptions: RequirementsNotMetException;

    DeviceContext device;
    assert(!requirementsEnabled!(Requirement!"samplerAnisotropy")(device, reason));

    device.enabled.samplerAnisotropy = VK_TRUE;
    assert(requirementsEnabled!(Requirement!"samplerAnisotropy")(device, reason));

    device.properties.limits.maxSamplerAnisotropy = 8;
    assert(!requirementsEnabled!(Requirement!("maxSamplerAnisotropy", 16))(device, reason));

    device.properties.limits.maxSamplerAnisotropy = 16;
    assert(requirementsEnabled!(Requirement!("maxSamplerAnisotropy", 16))(device, reason));

    DeviceContext disabled;
    assertThrown!RequirementsNotMetException(
        requireEnabled!(Requirement!"samplerAnisotropy")(disabled, "test"));
}
