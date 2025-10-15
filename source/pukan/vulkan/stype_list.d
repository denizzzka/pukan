module pukan.vulkan.stype_list;

import pukan.vulkan.bindings;
import std.meta;
import std.traits;

struct Entry(C, R, alias t)
{
    alias CreateInfoT = C;
    alias ResultT = R;
    enum VkStructureType sType = t;
}

alias ST = VkStructureType;

alias sType_list = AliasSeq!(
    Entry!(VkInstanceCreateInfo,        VkInstance,         ST.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO),
    Entry!(VkRenderPassCreateInfo,      VkRenderPass,       ST.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO),
    Entry!(VkPipelineLayoutCreateInfo,  VkPipelineLayout,   ST.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO),
    Entry!(VkBufferCreateInfo,          VkBuffer,           ST.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO), //FIXME: remove
    Entry!(VkMemoryAllocateInfo,        VkDeviceMemory,     ST.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO), //FIXME: remove
    Entry!(VkDescriptorSetLayoutCreateInfo, VkDescriptorSetLayout,  ST.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO),
    Entry!(VkDescriptorPoolCreateInfo,  VkDescriptorPool,   ST.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO),
    Entry!(VkImageCreateInfo,           VkImage,            ST.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO),
    Entry!(VkSamplerCreateInfo,         VkSampler,          ST.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO),
);

template getEntry(InfoT)
{
    static foreach(e; sType_list)
    {
        static if(is(e.CreateInfoT == InfoT))
            alias getEntry = e;
    }
}

template getCreateInfoStructureType(Tptr)
{
    alias T = PointerTarget!Tptr;

    enum VkStructureType getCreateInfoStructureType = getEntry!T.sType;
}

unittest
{
    enum x = getCreateInfoStructureType!(VkInstanceCreateInfo*);
    static assert(x == VkStructureType.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO);
}

template ResultType(T)
{
    alias ResultType = getEntry!T.ResultT;
}

unittest
{
    alias x = ResultType!VkMemoryAllocateInfo;
    static assert(is(x == VkDeviceMemory));
}
