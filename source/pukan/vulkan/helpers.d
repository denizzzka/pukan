module pukan.vulkan.helpers;

import pukan.exceptions: PukanExceptionWithCode;
import pukan.vulkan;
import pukan.vulkan.bindings;
public import pukan.vulkan.stype_list: ResultType, getCreateInfoStructureType;
import std.traits: PointerTarget;

auto vkCheck(VkResult ret, string err_descr = __FUNCTION__, string file = __FILE__, size_t line = __LINE__)
{
    if(ret != VkResult.VK_SUCCESS)
        throw new PukanExceptionWithCode(ret, err_descr, file, line);

    return ret;
}

private mixin template PrepareSettings(T...)
{
    enum findStings = ["CreateInfo", "AllocateInfo"];

    template IsCreateInfo(string findStr, T)
    {
        enum string typeName = T.stringof;

        enum IsCreateInfo =
            typeName.length > findStr.length &&
            typeName[$-findStr.length .. $] == findStr;
    }

    static foreach(i, E; T)
    {
        static foreach(findStr; findStings)
        {
            static if(IsCreateInfo!(findStr~"*", E))
            {
                enum createInfoIdx = i;
                enum resultNameSuffix = findStr;
            }
        }
    }

    static assert(__traits(compiles, createInfoIdx), findStr~" argument not found");

    alias TCreateInfo = T[createInfoIdx];

    static if(createInfoIdx == 0)
        enum methodsHaveThisPtr = false;
    else
    {
        enum methodsHaveThisPtr = true;
        T[0] vkThis;
    }

    alias BaseType = ResultType!(PointerTarget!TCreateInfo);

    enum _baseName = BaseType.stringof["Vk".length .. $-3];

    // special case
    static if(_baseName == "DeviceMemory")
        enum baseName = "Memory";
    else
        enum baseName = _baseName;

    static if(resultNameSuffix == "CreateInfo")
    {
        enum ctorName = "vkCreate"~baseName;
        enum dtorName = "vkDestroy"~baseName;
    }
    else static if(resultNameSuffix == "AllocateInfo")
    {
        enum ctorName = "vkAllocate"~baseName;
        enum dtorName = "vkFree"~baseName;
    }
    else
        static assert(false, "Suffix not supported: "~resultNameSuffix);
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

/// RAII VK object wrapper
class VkObj(T...)
{
    mixin PrepareSettings!T;

    VkAllocationCallbacks* allocator;
    BaseType vkObj;
    alias this = vkObj;

    this(T a)
    {
        // Placed out of debug scope to check release code too
        enum sTypeMustBe = getCreateInfoStructureType!TCreateInfo;

        debug
        {
            a[createInfoIdx].sType = sTypeMustBe;
        }

        static if(methodsHaveThisPtr)
            vkThis = a[0];

        allocator = a[createInfoIdx + 1];

        vkCall(a, &vkObj);
    }

    this(BaseType o, VkAllocationCallbacks* alloc)
    in(o !is null)
    {
        vkObj = o;
        allocator = alloc;
    }

    ~this()
    {
        static if(methodsHaveThisPtr)
            if(vkThis is null)
                return;

        mixin(dtorName~"("~(methodsHaveThisPtr ? "vkThis, " : "")~"vkObj, allocator);");
    }
}

/// Create RAII VK object
auto create(T...)(T s)
{
    return new VkObj!T(s);
}

/// Special helper to fetch values using methods like vkEnumeratePhysicalDevices
auto getArrayFrom(alias func, uint count = 0, T...)(T obj)
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

/// Destroys objects if ot null
void destr(T)(ref T obj)
{
    if(obj !is null)
        destroy(obj);
}
