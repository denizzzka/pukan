module pukan.vulkan.descriptors;

//TODO: rename to DescriptorPool
package mixin template DescriptorPools()
{
    import std.container.slist;
    private SList!VkDescriptorPool descriptorPools;

    ref auto createDescriptorPool()
    {
        descriptorPools.insert = VkDescriptorPool();

        return descriptorPools.front;
    }

    void descriptorsDtor()
    {
        foreach(e; descriptorPools)
            vkDestroyDescriptorPool(this.device, e, this.alloc);
    }
}

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;

class DescriptorPool
{
    LogicalDevice device;
    VkDescriptorSetLayout descriptorSetLayout;
    VkDescriptorPool descriptorPool;
    alias this = descriptorPool;

    this(LogicalDevice dev, VkDescriptorSetLayoutBinding[] descriptorSetLayoutBindings)
    {
        device = dev;

        {
            // In general, VkDescriptorSetLayoutCreateInfo are not related to any pool.
            // But for now it is convenient to place it here

            VkDescriptorSetLayoutCreateInfo descrLayoutCreateInfo = {
                bindingCount: cast(uint) descriptorSetLayoutBindings.length,
                pBindings: descriptorSetLayoutBindings.ptr,
            };

            vkCall(device.device, &descrLayoutCreateInfo, device.alloc, &descriptorSetLayout);
        }

        {
            VkDescriptorPoolSize[] poolSizes;
            poolSizes.length = descriptorSetLayoutBindings.length;

            foreach(i, ref poolSize; poolSizes)
            {
                poolSize.type = descriptorSetLayoutBindings[i].descriptorType;
                poolSize.descriptorCount = descriptorSetLayoutBindings[i].descriptorCount;
            }

            VkDescriptorPoolCreateInfo descriptorPoolInfo = {
                poolSizeCount: cast(uint) poolSizes.length,
                pPoolSizes: poolSizes.ptr,
                maxSets: 1,
            };

            vkCall(device.device, &descriptorPoolInfo, device.alloc, &descriptorPool);
        }
    }

    ~this()
    {
        if(descriptorPool)
            vkDestroyDescriptorPool(device, descriptorPool, device.alloc);

        if(descriptorSetLayout)
            vkDestroyDescriptorSetLayout(device, descriptorSetLayout, device.alloc);
    }

    auto allocateDescriptorSets(uint count)
    {
        VkDescriptorSetAllocateInfo descriptorSetAllocateInfo = {
            sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            descriptorPool: descriptorPool,
            descriptorSetCount: count,
            pSetLayouts: &descriptorSetLayout,
        };

        VkDescriptorSet[] ret;
        ret.length = count;
        vkAllocateDescriptorSets(device.device, &descriptorSetAllocateInfo, ret.ptr).vkCheck;

        return ret;
    }

    void updateSets(ref scope VkWriteDescriptorSet[] writeDescriptorSets)
    {
        vkUpdateDescriptorSets(device, cast(uint) writeDescriptorSets.length, writeDescriptorSets.ptr, 0, null);
    }
}

//TODO: unused, remove
VkDescriptorSetLayoutBinding[] createLayoutBinding(DescriptorSet)(DescriptorSet[] descriptorSets, VkShaderStageFlagBits[] stageFlags)
in(descriptorSets.length == stageFlags.length)
{
    VkDescriptorSetLayoutBinding[] ret;
    ret.length = descriptorSets.length;

    foreach(i, ref r; ret)
    {
        ref dsc = descriptorSets[i];

        r.binding = dsc.dstBinding;
        r.descriptorType = dsc.descriptorType;
        r.descriptorCount = dsc.descriptorCount;
        r.stageFlags = stageFlags[i];
    }

    return ret;
}
