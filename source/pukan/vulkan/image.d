module pukan.vulkan.image;

import pukan.exceptions: PukanException;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;

class ImageMemory : MemoryBufferBase
{
    VkImage image;
    alias this = image;
    VkExtent3D imageExtent;

    this(LogicalDevice device, ref VkImageCreateInfo createInfo, in VkMemoryPropertyFlags propFlags)
    {
        vkCall(device.device, &createInfo, device.backend.allocator, &image);

        imageExtent = createInfo.extent;

        VkMemoryRequirements memRequirements;
        vkGetImageMemoryRequirements(device, image, &memRequirements);

        super(device, memRequirements, propFlags);

        vkBindImageMemory(device, image, super.deviceMemory, 0 /* memoryOffset */).vkCheck;
    }

    ~this()
    {
        if(image)
            vkDestroyImage(device, image, device.backend.allocator);
    }

    void addPipelineBarrier(VkCommandBuffer buf, VkImageLayout oldLayout, VkImageLayout newLayout)
    {
        VkImageMemoryBarrier barrier;
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = oldLayout;
        barrier.newLayout = newLayout;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED; // same queue family used
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED; // ditto
        barrier.image = image;
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;

        VkPipelineStageFlags sourceStage;
        VkPipelineStageFlags destinationStage;

        if(oldLayout == VK_IMAGE_LAYOUT_UNDEFINED && newLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
        {
            barrier.srcAccessMask = VK_ACCESS_NONE;
            barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;

            sourceStage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
            destinationStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        }
        else if(oldLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL && newLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
        {
            barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;

            sourceStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
            destinationStage = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        }
        else
            throw new PukanException("unsupported layout transition!");

        vkCmdPipelineBarrier(
            buf,
            sourceStage,
            destinationStage,
            0, // dependencyFlags
            0, null,
            0, null,
            1, &barrier
        );
    }

    void copyFromBuffer(CommandPool commandPool, VkCommandBuffer buf, VkBuffer srcBuffer)
    {
        VkBufferImageCopy region;
        region.bufferOffset = 0;
        region.bufferRowLength = 0;
        region.bufferImageHeight = 0;

        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.mipLevel = 0;
        region.imageSubresource.baseArrayLayer = 0;
        region.imageSubresource.layerCount = 1;

        region.imageOffset = VkOffset3D(0, 0, 0);
        region.imageExtent = imageExtent;

        commandPool.recordOneTimeAndSubmit(buf, (buf){
            addPipelineBarrier(buf, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);

            vkCmdCopyBufferToImage(
                buf,
                srcBuffer,
                image,
                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                1, // regionCount
                &region
            );

            addPipelineBarrier(buf, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
        });
    }
}
