module pukan.vulkan.descriptors;

import pukan.vulkan.bindings;

package mixin template DescriptorPools()
{
    import std.container.slist;
    private VkDescriptorSetLayout[] descriptorLayouts;
    /* private FIXME*/ SList!PoolAndLayoutInfo descriptorPools;

    VkDescriptorSetLayout createDescriptorSetLayout(VkDescriptorSetLayoutBinding[] descriptorSetLayoutBindings)
    {
        VkDescriptorSetLayoutCreateInfo descrLayoutCreateInfo = {
            bindingCount: cast(uint) descriptorSetLayoutBindings.length,
            pBindings: descriptorSetLayoutBindings.ptr,
        };

        VkDescriptorSetLayout layout;
        vkCall(this.device, &descrLayoutCreateInfo, this.alloc, &layout);
        descriptorLayouts ~= layout;

        return layout;
    }

    ref PoolAndLayoutInfo createDescriptorPool(VkDescriptorSetLayoutBinding[] descriptorSetLayoutBindings, uint maxSets)
    {
        auto layout = createDescriptorSetLayout(descriptorSetLayoutBindings);

        return createDescriptorPool(layout, descriptorSetLayoutBindings, maxSets);
    }

    ref PoolAndLayoutInfo createDescriptorPool(
        VkDescriptorSetLayout layout,
        VkDescriptorSetLayoutBinding[] descriptorSetLayoutBindings,
        uint maxSets,
    )
    {
        VkDescriptorPoolSize[] poolSizes;

        foreach(ref binding; descriptorSetLayoutBindings)
        {
            size_t existing = poolSizes.length;

            foreach(i, ref poolSize; poolSizes)
                if(poolSize.type == binding.descriptorType)
                {
                    existing = i;
                    break;
                }

            if(existing == poolSizes.length)
                poolSizes ~= VkDescriptorPoolSize(binding.descriptorType, binding.descriptorCount * maxSets);
            else
                poolSizes[existing].descriptorCount += binding.descriptorCount * maxSets;
        }

        VkDescriptorPoolCreateInfo descriptorPoolInfo = {
            poolSizeCount: cast(uint) poolSizes.length,
            pPoolSizes: poolSizes.ptr,
            maxSets: maxSets,
        };

        VkDescriptorPool pool;
        vkCall(this.device, &descriptorPoolInfo, this.alloc, &pool);

        descriptorPools.insert(PoolAndLayoutInfo(
            descriptorPool: pool,
            descriptorSetLayout: layout,
        ));

        return descriptorPools.front;
    }

    private void descriptorPoolsDtor()
    {
        foreach(ref e; descriptorPools)
            if(e.descriptorPool)
                vkDestroyDescriptorPool(this.device, e.descriptorPool, this.alloc);

        foreach(layout; descriptorLayouts)
            vkDestroyDescriptorSetLayout(this.device, layout, this.alloc);
    }

    VkDescriptorSet allocateDescriptorSet(ref PoolAndLayoutInfo layout)
    {
        VkDescriptorSetAllocateInfo descriptorSetAllocateInfo = {
            sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            descriptorPool: layout.descriptorPool,
            descriptorSetCount: 1,
            pSetLayouts: &layout.descriptorSetLayout,
        };

        VkDescriptorSet ret;
        vkAllocateDescriptorSets(this.device, &descriptorSetAllocateInfo, &ret).vkCheck;

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

VkWriteDescriptorSet bufferWriteDescriptor(
    VkDescriptorSet dstSet,
    uint dstBinding,
    VkDescriptorType descriptorType,
    ref VkDescriptorBufferInfo bufferInfo,
)
{
    return VkWriteDescriptorSet(
        sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        dstSet: dstSet,
        dstBinding: dstBinding,
        dstArrayElement: 0,
        descriptorType: descriptorType,
        descriptorCount: 1,
        pBufferInfo: &bufferInfo,
    );
}

VkWriteDescriptorSet imageWriteDescriptor(
    VkDescriptorSet dstSet,
    uint dstBinding,
    VkDescriptorType descriptorType,
    ref VkDescriptorImageInfo imageInfo,
)
{
    return VkWriteDescriptorSet(
        sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        dstSet: dstSet,
        dstBinding: dstBinding,
        dstArrayElement: 0,
        descriptorType: descriptorType,
        descriptorCount: 1,
        pImageInfo: &imageInfo,
    );
}
