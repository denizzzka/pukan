module pukan.vulkan.image;

package mixin template Images()
{
    import lockfree.list: LockFreeList;

    private LockFreeList!VkImage images;

    auto createImage(ref VkImageCreateInfo createInfo)
    {
        return images.insertOne((e) => vkCall(this.device, &createInfo, this.alloc, &e));
    }

    private void imagesDtor()
    {
        foreach(e; images)
            vkDestroyImage(this.device, e, this.alloc);
    }
}

import pukan.exceptions: PukanVulkanException;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;

class ImageMemory : DeviceMemory
{
    VkImage image;
    alias this = image;
    VkExtent3D imageExtent;

    this(LogicalDevice device, ref VkImageCreateInfo createInfo, in VkMemoryPropertyFlags propFlags)
    {
        string reason;
        if(!device.supportsImageFormat(ImageFormatRequest.from(createInfo), reason))
            throw new PukanVulkanException(reason);

        image = device.createImage(createInfo);

        imageExtent = createInfo.extent;

        VkMemoryRequirements memRequirements;
        vkGetImageMemoryRequirements(device, image, &memRequirements);

        super(device, memRequirements, propFlags);

        vkBindImageMemory(device, image, super.deviceMemory, 0 /* memoryOffset */).vkCheck;
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
            throw new PukanVulkanException("unsupported layout transition!");

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

    /// Records the layout transitions and the copy; the source buffer must stay
    /// alive until the command buffer is submitted.
    void recordCopyFromBuffer(VkCommandBuffer buf, VkBuffer srcBuffer)
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
    }
}

/// Records the image upload into `commandBuf` and keeps the staging buffer in
/// `staging`, to be destroyed after the submit.
ImageMemory loadImageToMemory(Img)(LogicalDevice device, VkCommandBuffer commandBuf, ref Img image, in VkFormat pixelFormat, ref MemoryBufferMappedToCPU[] staging)
{
    VkDeviceSize imageSize;

    switch(pixelFormat)
    {
        case VK_FORMAT_R8G8B8A8_SRGB:
            imageSize = image.width * image.height * 4;
            break;

        case VK_FORMAT_R8G8B8_SRGB:
            imageSize = image.width * image.height * 3;
            break;

        default:
            import std.conv;
            import std.exception;
            enforce!PukanVulkanException(false, "Unsupported pixel format: "~pixelFormat.to!string);
            break;
    }

    //FIXME: TransferBuffer is used only as src buffer
    auto buf = device.create!MemoryBufferMappedToCPU(imageSize, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    staging ~= buf;

    buf.cpuBuf[0 .. $] = cast(void[]) image.allPixelsAtOnce;

    VkImageCreateInfo imageInfo = {
        imageType: VK_IMAGE_TYPE_2D,
        format: pixelFormat,
        tiling: VK_IMAGE_TILING_OPTIMAL,
        extent: VkExtent3D(
            width: image.width,
            height: image.height,
            depth: 1,
        ),
        mipLevels: 1,
        arrayLayers: 1,
        initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
        usage: VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
        sharingMode: VK_SHARING_MODE_EXCLUSIVE,
        samples: VK_SAMPLE_COUNT_1_BIT,
    };

    //TODO: implement check what VK_FORMAT_R8G8B8A8_SRGB is supported

    auto ret = device.create!ImageMemory(imageInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

    // TODO: fix ugly args naming
    ret.recordCopyFromBuffer(commandBuf, buf.buf);

    return ret;
}

/// Records and submits a single image upload.
ImageMemory loadImageToMemory(Img)(LogicalDevice device, CommandPool commandPool, VkCommandBuffer commandBuf, ref Img image, in VkFormat pixelFormat)
{
    ImageMemory ret;
    MemoryBufferMappedToCPU[] staging;

    commandPool.recordOneTimeAndSubmit(commandBuf, (buf) {
        ret = loadImageToMemory(device, buf, image, pixelFormat, staging);
    });

    foreach(buf; staging)
        destroy(buf);

    return ret;
}

auto createFakeImage1x1(LogicalDevice device, CommandPool commandPool, VkCommandBuffer commandBuf)
{
    static struct FakeImg
    {
        auto width() => 1;
        auto height() => 1;
        ubyte[] allPixelsAtOnce() => [0xff, 0xff, 0xff, 0xff]; //rgba
    }

    FakeImg extFormatImg;
    return loadImageToMemory(device, commandPool, commandBuf, extFormatImg, VK_FORMAT_R8G8B8A8_SRGB);
}
