module pukan.exceptions;

import std.conv: to;

class PukanException: Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure @safe
    {
        super(msg, file, line, nextInChain);
    }
}

class PukanExceptionWithCode: PukanException
{
    import pukan.vulkan.bindings: VkResult;

    VkResult code;

    this(VkResult code, string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure @safe
    {
        super(msg~": "~code.to!string, file, line, nextInChain);
        this.code = code;
    }
}

class PukanVulkanException: PukanException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure @safe
    {
        super(msg, file, line, nextInChain);
    }
}

class PukanVulkanExceptionWithCode: PukanVulkanException
{
    import pukan.vulkan.bindings: VkResult;

    VkResult code;

    this(VkResult code, string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure @safe
    {
        super(msg~": "~code.to!string, file, line, nextInChain);
        this.code = code;
    }
}

/// Thrown when an entity's optional requirements are not met
class RequirementsNotMetException: PukanVulkanException
{
    const string entity;
    const string[] missing;

    this(string entity, string[] missing, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure @safe
    {
        import std.array: join;

        this.entity = entity;
        this.missing = missing;
        super(entity ~ " requires " ~ missing.join(", "), file, line, nextInChain);
    }

    this(string entity, string reason, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure @safe
    {
        this.entity = entity;
        this.missing = [reason];
        super(entity ~ " requires " ~ reason, file, line, nextInChain);
    }
}
