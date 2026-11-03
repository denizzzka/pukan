module pukan.vulkan.descriptors;

import pukan.vulkan.bindings;
import pukan.vulkan.helpers: vkCall, vkCheck;
import pukan.vulkan.resources.vkobj: VkObj;

/// Descriptors of each type that `maxSets` sets of these bindings need
VkDescriptorPoolSize[] descriptorPoolSizes(
    scope const(VkDescriptorSetLayoutBinding)[] bindings,
    uint maxSets,
)
{
    VkDescriptorPoolSize[] poolSizes;

    foreach(ref binding; bindings)
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

    return poolSizes;
}

package mixin template DescriptorPools()
{
    import pukan.vulkan.descriptors: descriptorPoolSizes;

    /// Creates a set layout the caller owns; it must outlive the pools built from it
    VkObj!VkDescriptorSetLayout createDescriptorSetLayout(VkDescriptorSetLayoutBinding[] descriptorSetLayoutBindings)
    {
        synchronized(this)
        {
            return VkObj!VkDescriptorSetLayout(
                this.device,
                this.alloc,
                VkDescriptorSetLayoutCreateInfo(
                    bindingCount: cast(uint) descriptorSetLayoutBindings.length,
                    pBindings: descriptorSetLayoutBindings.ptr,
                ),
            );
        }
    }

    /// Creates a pool the caller frees; its sets die with a reset or the pool
    VkDescriptorPool createDescriptorPool(
        scope const(VkDescriptorSetLayoutBinding)[] bindings,
        uint maxSets,
    )
    {
        auto poolSizes = descriptorPoolSizes(bindings, maxSets);

        VkDescriptorPoolCreateInfo descriptorPoolInfo = {
            poolSizeCount: cast(uint) poolSizes.length,
            pPoolSizes: poolSizes.ptr,
            maxSets: maxSets,
        };

        VkDescriptorPool pool;
        vkCall(this.device, &descriptorPoolInfo, this.alloc, &pool);

        return pool;
    }

    VkDescriptorSet allocateDescriptorSet(VkDescriptorPool pool, VkDescriptorSetLayout layout)
    {
        VkDescriptorSetAllocateInfo descriptorSetAllocateInfo = {
            sType: VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            descriptorPool: pool,
            descriptorSetCount: 1,
            pSetLayouts: &layout,
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
