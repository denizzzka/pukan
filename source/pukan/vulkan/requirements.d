module pukan.vulkan.requirements;

import pukan.vulkan.api_version: VulkanVersion, requiredApiVersion, requiredApiVersionEncoded;
import pukan.vulkan.bindings;
import core.stdc.string: strcmp;
import std.conv: to;
import std.meta: AliasSeq, NoDuplicates, staticIndexOf, staticMap;
import std.typecons: Tuple;

private enum Kind { number, feature, chainFeature, extension, queue }

private template isNumberType(T)
{
    enum isNumberType =
        is(T == uint) || is(T == int) || is(T == ulong) || is(T == long) ||
        is(T == float) || is(T == double);
}

/// Declare optional requirements for an entity
template getOptionalRequirements(Reqs...)
{
    static foreach(R; Reqs)
        // The enabled chain is linked from required requirements only, before device creation
        static assert(!R.isChainFeature,
            "optional chain feature is not supported: " ~ R.requirementName);

    private import std.meta: AliasSeq;
    alias getOptionalRequirements = AliasSeq!Reqs;
}

/// Feature structures chained through VkPhysicalDeviceFeatures2, most preferred first
private alias featureStructs = AliasSeq!(
    VkPhysicalDeviceVulkan11Features,
    VkPhysicalDeviceVulkan12Features,
    VkPhysicalDeviceVulkan13Features,
    VkPhysicalDeviceVertexInputDynamicStateFeaturesEXT,
);

/// Storage for every known feature structure
alias FeatureChain = Tuple!featureStructs;

/// Version that introduced the structure, 1.0 for extension-only ones
private template featureStructVersion(T)
{
    static if(is(T == VkPhysicalDeviceVulkan11Features) || is(T == VkPhysicalDeviceVulkan12Features))
        enum featureStructVersion = VulkanVersion(1, 2);
    else static if(is(T == VkPhysicalDeviceVulkan13Features))
        enum featureStructVersion = VulkanVersion(1, 3);
    else
        enum featureStructVersion = VulkanVersion(1, 0);
}

/// Device extension that enables the structure, empty for core ones
private template featureStructExtension(T)
{
    static if(is(T == VkPhysicalDeviceVertexInputDynamicStateFeaturesEXT))
        enum featureStructExtension = "VK_EXT_vertex_input_dynamic_state";
    else
        enum featureStructExtension = "";
}

private template featureStructSType(T)
{
    static if(is(T == VkPhysicalDeviceVulkan11Features))
        enum featureStructSType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES;
    else static if(is(T == VkPhysicalDeviceVulkan12Features))
        enum featureStructSType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
    else static if(is(T == VkPhysicalDeviceVulkan13Features))
        enum featureStructSType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
    else static if(is(T == VkPhysicalDeviceVertexInputDynamicStateFeaturesEXT))
        enum featureStructSType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VERTEX_INPUT_DYNAMIC_STATE_FEATURES_EXT;
    else
        static assert(false, "unknown feature structure: " ~ T.stringof);
}

private template isFeatureStructField(T, string name)
{
    enum isFeatureStructField = __traits(hasMember, T, name) &&
        is(typeof(__traits(getMember, T, name)) == VkBool32);
}

/// Structures holding the given field, in registry order
private template structsWithField(string name, Structs...)
{
    static if(Structs.length == 0)
        alias structsWithField = AliasSeq!();
    else static if(isFeatureStructField!(Structs[0], name))
        alias structsWithField = AliasSeq!(Structs[0], structsWithField!(name, Structs[1 .. $]));
    else
        alias structsWithField = structsWithField!(name, Structs[1 .. $]);
}

/// Structure that owns the given chain feature field
private template OwnerOf(string name)
{
    alias candidates = structsWithField!(name, featureStructs);

    static assert(candidates.length > 0, "unknown Vulkan chain feature: " ~ name);
    static assert(candidates.length == 1, "ambiguous Vulkan chain feature: " ~ name);

    alias OwnerOf = candidates[0];
}

/// Position of the structure in the registry
private template chainIndex(T)
{
    enum chainIndex = staticIndexOf!(T, featureStructs);
}

/// Count of the VkBool32 fields of the structure
private template featureFieldCount(T)
{
    enum featureFieldCount = countFeatureFields!(T, __traits(allMembers, T));
}

private template countFeatureFields(T, Members...)
{
    static if(Members.length == 0)
        enum countFeatureFields = 0;
    else static if(isFeatureStructField!(T, Members[0]))
        enum countFeatureFields = 1 + countFeatureFields!(T, Members[1 .. $]);
    else
        enum countFeatureFields = countFeatureFields!(T, Members[1 .. $]);
}

private template fieldsBefore(T, Structs...)
{
    static if(Structs.length == 0)
        enum fieldsBefore = 0;
    else static if(is(Structs[0] == T))
        enum fieldsBefore = 0;
    else
        enum fieldsBefore = featureFieldCount!(Structs[0]) + fieldsBefore!(T, Structs[1 .. $]);
}

private template fieldIndexIn(T, string name, Members...)
{
    static if(Members.length == 0)
        enum fieldIndexIn = 0;
    else static if(Members[0] == name)
        enum fieldIndexIn = 0;
    else static if(isFeatureStructField!(T, Members[0]))
        enum fieldIndexIn = 1 + fieldIndexIn!(T, name, Members[1 .. $]);
    else
        enum fieldIndexIn = fieldIndexIn!(T, name, Members[1 .. $]);
}

private template totalFeatureFields(Structs...)
{
    static if(Structs.length == 0)
        enum totalFeatureFields = 0;
    else
        enum totalFeatureFields = featureFieldCount!(Structs[0]) + totalFeatureFields!(Structs[1 .. $]);
}

/// Bit of the given chain feature in ChainMask
/// The registry order flattens to one index, so a requirement keeps a stable bit
private template chainBitIndex(string name)
{
    alias owner = OwnerOf!name;

    enum chainBitIndex = fieldsBefore!(owner, featureStructs) +
        fieldIndexIn!(owner, name, __traits(allMembers, owner));
}

static assert(totalFeatureFields!featureStructs <= 128, "ChainMask covers 128 chain features");

/// Bits of the chain features enabled for a device
/// The flat field index splits into a word (bit / 64) and an offset (bit % 64)
struct ChainMask
{
    private ulong[2] words;

    /// True when the bit is set
    bool isSet(size_t bit) const
    {
        return (words[bit / 64] & (1UL << (bit % 64))) != 0;
    }

    /// Sets the bit
    void set(size_t bit)
    {
        words[bit / 64] |= 1UL << (bit % 64);
    }
}

private template requirementOwner(R)
{
    static if(__traits(hasMember, R, "owner"))
        alias requirementOwner = R.owner;
    else
        alias requirementOwner = void;
}

private template structReferenced(T, Reqs...)
{
    static if(Reqs.length == 0)
        enum structReferenced = false;
    else static if(is(requirementOwner!(Reqs[0]) == T))
        enum structReferenced = true;
    else
        enum structReferenced = structReferenced!(T, Reqs[1 .. $]);
}

private template requirementKind(string name)
{
    static if(name.length > 3 && name[0 .. 3] == "VK_")
        enum requirementKind = Kind.extension;
    else static if(__traits(hasMember, VkPhysicalDeviceFeatures, name) &&
        is(typeof(__traits(getMember, VkPhysicalDeviceFeatures, name)) == VkBool32))
        enum requirementKind = Kind.feature;
    else static if(structsWithField!(name, featureStructs).length > 0)
        enum requirementKind = Kind.chainFeature;
    else static if(__traits(hasMember, VkQueueFamilyProperties, name) &&
        is(typeof(__traits(getMember, VkQueueFamilyProperties, name)) == VkQueueFlags))
        enum requirementKind = Kind.queue;
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
    VkPhysicalDevice device;
    VkPhysicalDeviceProperties properties;
    VkPhysicalDeviceFeatures supported;
    VkPhysicalDeviceFeatures enabled;
    ChainMask enabledChainMask;
    VkQueueFamilyProperties[] queueFamilies;
    VkQueueFlags selectedQueueFlags;
    VkExtensionProperties[] supportedExtensions;
    const(char)*[] enabledExtensions;
    version(assert)
    {
        /// Guards against running a request step twice
        private bool requiredRequested;
        private bool optionalRequested;
    }

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

/// Device requirement: a number, a feature (base or chained), queue flags or an extension
/// Numbers and queue flags take a value; features and extensions take none
template Requirement(alias source, ulong minimum = 0)
{
    /// Field symbols take their own name, string constants their value
    static if(is(typeof(source) == string))
        private enum string name = source;
    else
        private enum string name = __traits(identifier, source);

    alias Requirement = RequirementImpl!(name, minimum);
}

private struct RequirementImpl(string name, ulong minimum)
{
    package enum kind = requirementKind!name;

    /// True when this is a device/instance extension
    enum bool isExtension = kind == Kind.extension;
    /// True when this is a VkBool32 feature of VkPhysicalDeviceFeatures
    enum bool isFeature = kind == Kind.feature;
    /// True when this is a VkBool32 feature of a chained structure
    enum bool isChainFeature = kind == Kind.chainFeature;

    /// Structure that owns the chained feature
    static if(kind == Kind.chainFeature)
        alias owner = OwnerOf!name;

    /// Vulkan version that introduced the chained structure, if any
    static if(kind == Kind.chainFeature)
        package enum VulkanVersion requiredVersion = featureStructVersion!owner;
    else
        package enum VulkanVersion requiredVersion = VulkanVersion(1, 0);

    /// Name used in diagnostics
    enum string requirementName = name;
    /// Minimum value or flags the requirement asks for
    package enum ulong requirementMinimum = minimum;

    static if(kind == Kind.feature)
        static assert(minimum == 0, "feature requirement takes no minimum: " ~ name);
    else static if(kind == Kind.chainFeature)
        static assert(minimum == 0, "feature requirement takes no minimum: " ~ name);
    else static if(kind == Kind.extension)
        static assert(minimum == 0, "extension requirement takes no minimum: " ~ name);
    else static if(kind == Kind.queue)
        static assert(minimum != 0, "queue requirement needs flags: " ~ name);

    /// Returns false and a reason when the requirement is not met
    static bool isSatisfied(Ctx)(ref Ctx ctx, out string reason) if(is(Ctx == DeviceContext))
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
        else static if(kind == Kind.chainFeature)
            static assert(false, "chain features are checked during the device query: " ~ name);
        else static if(kind == Kind.queue)
        {
            const required = cast(VkQueueFlags) minimum;

            foreach(f; ctx.queueFamilies)
                if((f.queueFlags & required) == required)
                    return true;

            reason = "no queue family with flags " ~ required.to!string;
            return false;
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

    static if(kind == Kind.chainFeature)
    {
        /// Returns false and a reason when the chain feature is not supported
        static bool isSupportedBy(ref const FeatureChain chain, out string reason)
        {
            if(__traits(getMember, chain[chainIndex!owner], name) != VK_TRUE)
            {
                reason = "feature is not supported: " ~ name;
                return false;
            }

            return true;
        }
    }

    /// Records the chain feature in the mask; numbers and queue flags have nothing to request
    static void request(ref DeviceContext ctx)
    {
        static if(kind == Kind.feature)
            __traits(getMember, ctx.enabled, name) = VK_TRUE;
        else static if(kind == Kind.chainFeature)
            ctx.enabledChainMask.set(chainBitIndex!name);
        else static if(kind == Kind.extension)
        {
            // Required and optional are requested in separate calls, so skip a name already enabled
            if(!ctx.hasEnabledExtension(name))
                ctx.enabledExtensions ~= name.ptr;
        }
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
        else static if(kind == Kind.chainFeature)
        {
            if(!ctx.enabledChainMask.isSet(chainBitIndex!name))
            {
                reason = "feature is not enabled: " ~ name;
                return false;
            }
        }
        else static if(kind == Kind.queue)
        {
            const required = cast(VkQueueFlags) minimum;

            if((ctx.selectedQueueFlags & required) != required)
            {
                reason = "queue flags are not enabled: " ~ required.to!string;
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

/// Queries the features referenced by Reqs, keeping the chain values on the stack only
bool queryDeviceFeatures(Reqs...)(VkPhysicalDevice device, ref DeviceContext ctx, out string reason)
{
    VkPhysicalDeviceFeatures2 head = {
        sType: VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
    };
    FeatureChain chain;

    static foreach(i, T; featureStructs)
    {{
        static if(structReferenced!(T, Reqs))
        {
            chain[i].sType = featureStructSType!T;
            chain[i].pNext = head.pNext;
            head.pNext = &chain[i];
        }
    }}

    vkGetPhysicalDeviceFeatures2(device, &head);
    ctx.supported = head.features;

    static foreach(R; Reqs)
        static if(R.isChainFeature)
            if(!R.isSupportedBy(chain, reason))
                return false;

    return true;
}

/// Fills the chain with the features required by Reqs
void fillFeatureChain(Reqs...)(ref FeatureChain chain)
{
    static foreach(R; Reqs)
        static if(R.isChainFeature)
        {
            auto ref slot = chain[chainIndex!(R.owner)];
            slot.sType = featureStructSType!(R.owner);
            __traits(getMember, slot, R.requirementName) = VK_TRUE;
        }
}

/// Links the requested chain features into head
void linkDeviceFeatures(ref FeatureChain chain, ref VkPhysicalDeviceFeatures2 head)
{
    head.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    head.pNext = null;

    static foreach(i; 0 .. featureStructs.length)
    {
        if(cast(int) chain[i].sType != 0)
        {
            chain[i].pNext = head.pNext;
            head.pNext = &chain[i];
        }
    }
}

/// Requirement for a format with the given optimal tiling features
struct FormatRequirement(VkFormat format, VkFormatFeatureFlags features)
{
    enum string requirementName = format.stringof ~ " " ~ features.stringof;
    enum bool isExtension = false;
    enum bool isFeature = false;
    enum bool isChainFeature = false;
    package enum VulkanVersion requiredVersion = VulkanVersion(1, 0);

    /// Returns false and a reason when the format lacks the features
    static bool isSatisfied(Ctx)(ref Ctx ctx, out string reason) if(is(Ctx == DeviceContext))
    {
        return checkFormat(ctx.device, reason);
    }

    /// Formats are checked, not enabled at device creation
    static void request(ref DeviceContext ctx)
    {
    }

    /// Returns false and a reason when the format lacks the features
    static bool isEnabled(ref const DeviceContext ctx, out string reason)
    {
        return checkFormat(cast(VkPhysicalDevice) ctx.device, reason);
    }

    private static bool checkFormat(VkPhysicalDevice device, out string reason)
    {
        VkFormatProperties properties;
        vkGetPhysicalDeviceFormatProperties(device, format, &properties);

        if((properties.optimalTilingFeatures & features) != features)
        {
            reason = "format lacks features: " ~ requirementName;
            return false;
        }

        return true;
    }
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

/// Device extension that provides the chained structure of R, empty if core
private template chainExtension(R)
{
    static if(__traits(hasMember, R, "owner"))
        enum chainExtension = featureStructExtension!(R.owner);
    else
        enum chainExtension = "";
}

/// True when every chain feature is declared together with its device extension
private template chainExtensionsDeclared(Reqs...)
{
    static if(Reqs.length == 0)
        enum chainExtensionsDeclared = true;
    else static if(chainExtension!(Reqs[0]).length > 0)
        enum chainExtensionsDeclared =
            contains!(Requirement!(chainExtension!(Reqs[0])), Reqs) &&
            chainExtensionsDeclared!(Reqs[1 .. $]);
    else
        enum chainExtensionsDeclared = chainExtensionsDeclared!(Reqs[1 .. $]);
}

/// Union of the requirements declared by the given subsystems, without duplicates
template Requirements(Modules...)
{
    private alias reqs = NoDuplicates!(staticMap!(moduleRequirements, Modules));

    static assert(chainExtensionsDeclared!reqs,
        "a chain feature requires its device extension in the same requirement set");

    alias Requirements = reqs;
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

/// Optional requirements minus everything Required covers
template OptionalRequirementsWithout(Required...)
{
    /// Optional requirements not covered by Required
    template Of(Optional...)
    {
        private template keep(R)
        {
            static if(contains!(R, Required))
                alias keep = AliasSeq!();
            else
                alias keep = AliasSeq!(R);
        }

        alias Of = staticMap!(keep, NoDuplicates!Optional);
    }
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

    private alias reqs = NoDuplicates!(staticMap!(moduleRequired, Modules));

    static assert(chainExtensionsDeclared!reqs,
        "a chain feature requires its device extension in the same requirement set");

    alias RequirementsFor = reqs;
}

/// Names of the extension requirements in Reqs
template extensionNames(Reqs...)
{
    private string[] collect()
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
alias ApiVersionRequirement = Requirement!(VkPhysicalDeviceProperties.apiVersion, requiredApiVersionEncoded);

/// Highest Vulkan version the requirements imply, ignoring the library baseline
template RequirementsVersion(Reqs...)
{
    private VulkanVersion maxVersion()
    {
        VulkanVersion ret = VulkanVersion(1, 0);

        static foreach(R; Reqs)
            if(R.requiredVersion > ret)
                ret = R.requiredVersion;

        return ret;
    }

    enum RequirementsVersion = maxVersion();
}

/// Vulkan version the requirements need, never below the library baseline
template ApiVersionFor(Reqs...)
{
    enum ApiVersionFor = RequirementsVersion!Reqs > requiredApiVersion
        ? RequirementsVersion!Reqs
        : requiredApiVersion;
}

/// Queue flags the requirements need
template QueueFlagsFor(Reqs...)
{
    private VkQueueFlags collect()
    {
        VkQueueFlags ret;

        static foreach(R; Reqs)
            static if(__traits(hasMember, R, "kind") && R.kind == Kind.queue)
                ret |= cast(VkQueueFlags) R.requirementMinimum;

        return ret;
    }

    enum QueueFlagsFor = collect();
}

/// Returns true when every requirement is satisfied, otherwise fills the reason
bool requirementsSatisfied(Reqs...)(ref DeviceContext ctx, out string reason)
{
    static foreach(R; NoDuplicates!Reqs)
        // Chain features have no stored snapshot; queryDeviceFeatures checks them
        static if(!R.isChainFeature)
            if(!R.isSatisfied(ctx, reason))
                return false;

    return true;
}

/// Enables every requested feature and extension
void requestRequirements(Reqs...)(ref DeviceContext ctx)
{
    version(assert)
    {
        assert(!ctx.requiredRequested, "requestRequirements was already called");
        ctx.requiredRequested = true;
    }

    static foreach(R; NoDuplicates!Reqs)
        R.request(ctx);
}

/// Enables optional features and extensions if they are supported, otherwise skips them
void requestOptionalRequirements(Reqs...)(ref DeviceContext ctx)
{
    version(assert)
    {
        assert(!ctx.optionalRequested, "requestOptionalRequirements was already called");
        ctx.optionalRequested = true;
    }

    static foreach(R; NoDuplicates!Reqs)
    {{
        // The enabled chain is linked from required requirements only, before device creation
        static assert(!R.isChainFeature, "optional chain feature is not supported: " ~ R.requirementName);

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
    string reason;

    static assert(Requirement!(VkPhysicalDeviceFeatures.samplerAnisotropy).kind == Kind.feature);
    static assert(Requirement!(VkPhysicalDeviceLimits.maxComputeWorkGroupInvocations, 256).kind == Kind.number);
    static assert(Requirement!(VK_KHR_SWAPCHAIN_EXTENSION_NAME).kind == Kind.extension);
    static assert(Requirement!(VkPhysicalDeviceProperties.apiVersion, VulkanVersion(1, 3).toUint()).kind == Kind.number);
    static assert(Requirement!(VkPhysicalDeviceLimits.maxComputeWorkGroupInvocations, 256).requirementName ==
        "maxComputeWorkGroupInvocations");
    static assert(!__traits(compiles, Requirement!VkPhysicalDeviceLimits));

    static assert(Requirement!(VkPhysicalDeviceVulkan13Features.dynamicRendering).kind == Kind.chainFeature);
    static assert(is(Requirement!(VkPhysicalDeviceVulkan13Features.dynamicRendering).owner ==
        VkPhysicalDeviceVulkan13Features));
    static assert(Requirement!(VkPhysicalDeviceVulkan13Features.dynamicRendering).requiredVersion == VulkanVersion(1, 3));
    static assert(Requirement!(VkPhysicalDeviceVulkan11Features.storageBuffer16BitAccess).requiredVersion ==
        VulkanVersion(1, 2));
    static assert(RequirementsVersion!() == VulkanVersion(1, 0));
    static assert(RequirementsVersion!(
        Requirement!(VkPhysicalDeviceVulkan11Features.storageBuffer16BitAccess),
        Requirement!(VkPhysicalDeviceVulkan13Features.synchronization2),
    ) == VulkanVersion(1, 3));
    static assert(ApiVersionFor!(Requirement!(VkPhysicalDeviceVulkan11Features.storageBuffer16BitAccess)) ==
        requiredApiVersion);

    static struct ChainOnly
    {
        private alias requirements = AliasSeq!(
            Requirement!(VkPhysicalDeviceVertexInputDynamicStateFeaturesEXT.vertexInputDynamicState));
    }
    static struct ChainWithExtension
    {
        private alias requirements = AliasSeq!(
            Requirement!(VkPhysicalDeviceVertexInputDynamicStateFeaturesEXT.vertexInputDynamicState),
            Requirement!(VK_EXT_vertex_input_dynamic_state));
    }
    static assert(!__traits(compiles, Requirements!ChainOnly));
    static assert(__traits(compiles, Requirements!ChainWithExtension));
    static assert(!__traits(compiles, getOptionalRequirements!(
        Requirement!(VkPhysicalDeviceVulkan13Features.dynamicRendering))));

    DeviceContext chainCtx;
    alias dynamicRendering = Requirement!(VkPhysicalDeviceVulkan13Features.dynamicRendering);
    assert(!requirementsEnabled!dynamicRendering(chainCtx, reason));
    dynamicRendering.request(chainCtx);
    assert(chainCtx.enabledChainMask.isSet(chainBitIndex!"dynamicRendering"));
    assert(requirementsEnabled!dynamicRendering(chainCtx, reason));

    FeatureChain chain;
    fillFeatureChain!dynamicRendering(chain);
    assert(chain[chainIndex!VkPhysicalDeviceVulkan13Features].sType ==
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES);
    assert(chain[chainIndex!VkPhysicalDeviceVulkan13Features].dynamicRendering == VK_TRUE);

    VkPhysicalDeviceFeatures2 head;
    linkDeviceFeatures(chain, head);
    assert(head.pNext is &chain[chainIndex!VkPhysicalDeviceVulkan13Features]);

    FeatureChain supported;
    supported[chainIndex!VkPhysicalDeviceVulkan13Features].dynamicRendering = VK_TRUE;
    assert(dynamicRendering.isSupportedBy(supported, reason));

    alias swapchain = Requirement!(VK_KHR_SWAPCHAIN_EXTENSION_NAME);
    swapchain.request(chainCtx);
    swapchain.request(chainCtx);
    assert(chainCtx.enabledExtensions.length == 1);

    alias graphicsQueue = Requirement!(VkQueueFamilyProperties.queueFlags, VK_QUEUE_GRAPHICS_BIT);
    static assert(graphicsQueue.kind == Kind.queue);
    static assert(QueueFlagsFor!graphicsQueue == VK_QUEUE_GRAPHICS_BIT);

    DeviceContext queueCtx;
    queueCtx.queueFamilies = [
        VkQueueFamilyProperties(queueFlags: 0),
        VkQueueFamilyProperties(queueFlags: VK_QUEUE_GRAPHICS_BIT),
    ];
    assert(requirementsSatisfied!graphicsQueue(queueCtx, reason));
    assert(!requirementsEnabled!graphicsQueue(queueCtx, reason));

    queueCtx.selectedQueueFlags = VK_QUEUE_GRAPHICS_BIT;
    assert(requirementsEnabled!graphicsQueue(queueCtx, reason));

    DeviceContext noQueue;
    assert(!requirementsSatisfied!graphicsQueue(noQueue, reason));

    alias depth = FormatRequirement!(VK_FORMAT_D24_UNORM_S8_UINT,
        VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT);
    static assert(!depth.isExtension && !depth.isFeature && !depth.isChainFeature);
    static assert(RequirementsVersion!depth == VulkanVersion(1, 0));
    static assert(QueueFlagsFor!depth == 0);

    static struct A { private alias requirements = AliasSeq!(Requirement!(VkPhysicalDeviceFeatures.samplerAnisotropy)); }
    static struct B { private alias requirements = AliasSeq!(Requirement!(VkPhysicalDeviceFeatures.samplerAnisotropy)); }
    static assert(Requirements!(A, B).length == 1);

    static struct Opt
    {
        private alias optionalRequirements = AliasSeq!(
            Requirement!(VkPhysicalDeviceFeatures.samplerAnisotropy),
            Requirement!(VK_KHR_SWAPCHAIN_EXTENSION_NAME),
        );
    }
    static assert(OptionalRequirementsWithout!(Requirements!A).Of!(OptionalRequirementsOf!Opt).length == 1);
    static assert(is(OptionalRequirementsWithout!(Requirements!A).Of!(OptionalRequirementsOf!Opt)[0] ==
        Requirement!(VK_KHR_SWAPCHAIN_EXTENSION_NAME)));

    static assert(contains!(int, int, float));
    static assert(!contains!(double, int, float));

    InstanceContext instance;
    instance.loaderVersion = VulkanVersion(1, 2);

    assert(!ApiVersionRequirement.isSatisfied(instance, reason));
    assert(reason.length > 0);

    instance.loaderVersion = VulkanVersion(1, 3);
    assert(ApiVersionRequirement.isSatisfied(instance, reason));

    import std.exception: assertThrown;
    import core.exception: AssertError;
    import pukan.exceptions: RequirementsNotMetException;

    DeviceContext device;
    assert(!requirementsEnabled!(Requirement!(VkPhysicalDeviceFeatures.samplerAnisotropy))(device, reason));

    device.enabled.samplerAnisotropy = VK_TRUE;
    assert(requirementsEnabled!(Requirement!(VkPhysicalDeviceFeatures.samplerAnisotropy))(device, reason));

    device.properties.limits.maxSamplerAnisotropy = 8;
    assert(!requirementsEnabled!(Requirement!(VkPhysicalDeviceLimits.maxSamplerAnisotropy, 16))(device, reason));

    device.properties.limits.maxSamplerAnisotropy = 16;
    assert(requirementsEnabled!(Requirement!(VkPhysicalDeviceLimits.maxSamplerAnisotropy, 16))(device, reason));

    DeviceContext disabled;
    assertThrown!RequirementsNotMetException(
        requireEnabled!(Requirement!(VkPhysicalDeviceFeatures.samplerAnisotropy))(disabled, "test"));

    version(assert)
    {
        DeviceContext requested;
        requestRequirements!swapchain(requested);

        bool rejected;
        try
            requestRequirements!swapchain(requested);
        catch(AssertError)
            rejected = true;
        assert(rejected, "second requestRequirements was not rejected");

        DeviceContext requestedOptional;
        requestOptionalRequirements!swapchain(requestedOptional);

        rejected = false;
        try
            requestOptionalRequirements!swapchain(requestedOptional);
        catch(AssertError)
            rejected = true;
        assert(rejected, "second requestOptionalRequirements was not rejected");
    }
}
