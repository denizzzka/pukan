module pukan.vulkan.helpers;

import pukan.exceptions: PukanVulkanExceptionWithCode;
import pukan.vulkan;
import pukan.vulkan.bindings;
public import pukan.vulkan.stype_list: getCreateInfoStructureType;
public import pukan.vulkan.vkobj: VkObj;
import pukan.vulkan.vkname: VkInfoNames;

auto vkCheck(VkResult ret, string err_descr = __FUNCTION__, string file = __FILE__, size_t line = __LINE__)
{
    if(ret != VkResult.VK_SUCCESS)
        throw new PukanVulkanExceptionWithCode(ret, err_descr, file, line);

    return ret;
}

private mixin template PrepareSettings(T...)
{
    enum findStrings = ["CreateInfo", "AllocateInfo"];

    template IsCreateInfo(string findStr, T)
    {
        enum string typeName = T.stringof;

        enum IsCreateInfo =
            typeName.length > findStr.length &&
            typeName[$-findStr.length .. $] == findStr;
    }

    static foreach(i, E; T)
    {
        static foreach(findStr; findStrings)
        {
            static if(IsCreateInfo!(findStr~"*", E))
                enum createInfoIdx = i;
        }
    }

    static assert(__traits(compiles, createInfoIdx), findStrings[0]~" argument not found");

    alias TCreateInfo = T[createInfoIdx];

    enum ctorName = VkInfoNames!(TCreateInfo.stringof).create;
    enum baseName = VkInfoNames!(TCreateInfo.stringof).base;
}

void vkCall(T...)(T a)
{
    mixin PrepareSettings!T;

    // Placed out of debug scope to check release code too
    enum sTypeMustBe = getCreateInfoStructureType!TCreateInfo;

    debug
    {
        a[createInfoIdx].sType = sTypeMustBe;
    }

    mixin("VkResult r = "~ctorName~"(a);");
    r.vkCheck(baseName~" creation failed");
}

/// Special helper to fetch values using methods like vkEnumeratePhysicalDevices
auto getArrayFrom(alias func, uint count = 0, T...)(auto ref T obj)
{
    import std.traits;

    static if(count != 0)
        uint count = count;
    else
    {
        // First func call used to obtain count value
        uint count;

        static if(is(ReturnType!func == void))
            func(obj, &count, null);
        else
            func(obj, &count, null).vkCheck;
    }

    enum len = Parameters!func.length;
    alias Tptr = Parameters!func[len-1];

    PointerTarget!Tptr[] ret;

    if(count > 0)
    {
        ret.length = count;

        static if(is(ReturnType!func == void))
            func(obj, &count, ret.ptr);
        else
            func(obj, &count, ret.ptr).vkCheck;
    }

    return ret;
}

/// Print current stack trace
void printStackTrace()
{
    import core.runtime;
    import std.stdio;

    scope trace = defaultTraceHandler(null);

    foreach (line; trace)
        line.writeln;

    defaultTraceDeallocator(trace);
}

debug version = PukanVulkanCodeSanitizer;

/// Wrapper for a mixin template to prevent accessing external variables except .this
mixin template ScopedLogicalDeviceTemplateMixin(alias M)
{
    version(PukanVulkanCodeSanitizer)
    {
        // Just compile template mixin twice, once inside of the unused class:
        private static class Enclosure
        {
            import pukan.vulkan.bindings;

            // Only these two variables are needed to be accessible from a template mixins:
            VkDevice device;
            VkAllocationCallbacks* alloc;

            mixin M;
        }
    }

     mixin M;
}
