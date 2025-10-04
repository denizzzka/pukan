module pukan.vulkan.descriptors;

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
                maxSets: 1, // TODO: number of frames
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

    auto allocateDescriptorSets(VkDescriptorSetLayout[] layouts)
    {
        VkDescriptorSetAllocateInfo descriptorSetAllocateInfo = {
            sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            descriptorPool: descriptorPool,
            descriptorSetCount: cast(uint) layouts.length,
            pSetLayouts: layouts.ptr,
        };

        VkDescriptorSet[] descriptorSets;
        descriptorSets.length = cast(uint) layouts.length;
        vkAllocateDescriptorSets(device.device, &descriptorSetAllocateInfo, descriptorSets.ptr).vkCheck;

        return descriptorSets;
    }

    void updateSets(VkWriteDescriptorSet[] writeDescriptorSets)
    {
        vkUpdateDescriptorSets(device, cast(uint) writeDescriptorSets.length, writeDescriptorSets.ptr, 0, null);
    }
}

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
