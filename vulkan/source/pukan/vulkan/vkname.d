module pukan.vulkan.vkname;

/// Base name of a Vulkan create or allocate info type
template VkInfoBase(string name)
{
    enum createSuffix = "CreateInfo";
    enum allocateSuffix = "AllocateInfo";

    static if(name.length > createSuffix.length && name[$ - createSuffix.length .. $] == createSuffix)
        enum VkInfoBase = name["Vk".length .. $ - createSuffix.length];
    else static if(name.length > allocateSuffix.length && name[$ - allocateSuffix.length .. $] == allocateSuffix)
        enum VkInfoBase = name["Vk".length .. $ - allocateSuffix.length];
    else
        static assert(false, "unsupported create info: " ~ name);
}

/// Create and destroy function names for a Vulkan create or allocate info type
template VkInfoNames(string name)
{
    enum infoName = name.length > 0 && name[$ - 1] == '*' ? name[0 .. $ - 1] : name;
    enum base = VkInfoBase!infoName;
    enum isAllocate =
        infoName.length > "AllocateInfo".length &&
        infoName[$ - "AllocateInfo".length .. $] == "AllocateInfo";

    static if(isAllocate)
    {
        enum create = "vkAllocate" ~ base;
        enum destroy = "vkFree" ~ base;
    }
    else
    {
        enum create = "vkCreate" ~ base;
        enum destroy = "vkDestroy" ~ base;
    }
}

unittest
{
    static assert(VkInfoBase!"VkSemaphoreCreateInfo" == "Semaphore");
    static assert(VkInfoBase!"VkMemoryAllocateInfo" == "Memory");
    static assert(VkInfoNames!"VkSemaphoreCreateInfo*".create == "vkCreateSemaphore");
    static assert(VkInfoNames!"VkSemaphoreCreateInfo*".destroy == "vkDestroySemaphore");
    static assert(VkInfoNames!"VkMemoryAllocateInfo*".create == "vkAllocateMemory");
    static assert(VkInfoNames!"VkMemoryAllocateInfo*".destroy == "vkFreeMemory");
}
