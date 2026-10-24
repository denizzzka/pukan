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
