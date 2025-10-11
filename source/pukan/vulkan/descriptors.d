module pukan.vulkan.descriptors;

import pukan.vulkan.bindings;

package mixin template DescriptorPools()
{
    import std.container.slist;
    /* private FIXME*/ SList!PoolAndLayoutInfo descriptorPools;

    ref PoolAndLayoutInfo createDescriptorPool(VkDescriptorSetLayoutBinding[] descriptorSetLayoutBindings)
    {
        {
            // In general, VkDescriptorSetLayoutCreateInfo are not related to any pool.
            // But for now it is convenient to place it here

            VkDescriptorSetLayoutCreateInfo descrLayoutCreateInfo = {
                bindingCount: cast(uint) descriptorSetLayoutBindings.length,
                pBindings: descriptorSetLayoutBindings.ptr,
            };

            PoolAndLayoutInfo add;
            vkCall(this.device, &descrLayoutCreateInfo, this.alloc, &add.descriptorSetLayout);
            descriptorPools.insert(add);
        }

        VkDescriptorPool descriptorPool;

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

            vkCall(this.device, &descriptorPoolInfo, this.alloc, &descriptorPools.front.descriptorPool);
        }

        return descriptorPools.front;
    }

    void descriptorPoolsDtor()
    {
        foreach(ref e; descriptorPools)
        {
            // always unconditionally exists
            vkDestroyDescriptorSetLayout(this.device, e.descriptorSetLayout, this.alloc);

            if(e.descriptorPool)
                vkDestroyDescriptorPool(this.device, e.descriptorPool, this.alloc);
        }
    }

    auto allocateDescriptorSets(ref PoolAndLayoutInfo layout, uint count)
    {
        VkDescriptorSetAllocateInfo descriptorSetAllocateInfo = {
            sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            descriptorPool: layout.descriptorPool,
            descriptorSetCount: count,
            pSetLayouts: &layout.descriptorSetLayout,
        };

        VkDescriptorSet[] ret;
        ret.length = count;
        vkAllocateDescriptorSets(this.device, &descriptorSetAllocateInfo, ret.ptr).vkCheck;

        return ret;
    }

    void updateDescriptorSets(ref scope VkWriteDescriptorSet[] writeDescriptorSets)
    {
        vkUpdateDescriptorSets(device, cast(uint) writeDescriptorSets.length, writeDescriptorSets.ptr, 0, null);
    }
}

struct PoolAndLayoutInfo
{
    VkDescriptorPool descriptorPool;
    VkDescriptorSetLayout descriptorSetLayout;
}
