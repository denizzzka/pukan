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
    VkFormat format;
    uint mipLevels;

    this(LogicalDevice device, ref VkImageCreateInfo createInfo, in VkMemoryPropertyFlags propFlags)
    {
        // Release relies on the startup requirements; this catches runtime parameters
        debug
        {
            string reason;
            if(!device.supportsImageFormat(ImageFormatRequest.from(createInfo), reason))
                throw new PukanVulkanException(reason);
        }

        image = device.createImage(createInfo);

        imageExtent = createInfo.extent;
        format = createInfo.format;
        mipLevels = createInfo.mipLevels;

        VkMemoryRequirements memRequirements;
        vkGetImageMemoryRequirements(device, image, &memRequirements);

        super(device, memRequirements, propFlags);

        vkBindImageMemory(device, image, super.deviceMemory, 0 /* memoryOffset */).vkCheck;
    }

    void addPipelineBarrier(
        VkCommandBuffer buf,
        VkImageLayout oldLayout,
        VkImageLayout newLayout,
        uint baseMipLevel = 0,
        uint levelCount = 1,
    )
    {
        VkImageMemoryBarrier barrier;
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = oldLayout;
        barrier.newLayout = newLayout;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED; // same queue family used
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED; // ditto
        barrier.image = image;
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.baseMipLevel = baseMipLevel;
        barrier.subresourceRange.levelCount = levelCount;
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
        else if(oldLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL && newLayout == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
        {
            barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;

            sourceStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
            destinationStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        }
        else if(oldLayout == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL && newLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL)
        {
            barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
            barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;

            sourceStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
            destinationStage = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
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

        if(mipLevels < 2)
        {
            addPipelineBarrier(buf, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
            return;
        }

        addPipelineBarrier(buf, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
        generateMipmaps(buf);
        addPipelineBarrier(
            buf,
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            0,
            mipLevels,
        );
    }

    /// Copies one mip level from the source buffer at `bufferOffset`
    void recordCopyLevel(
        VkCommandBuffer buf,
        VkBuffer srcBuffer,
        VkDeviceSize bufferOffset,
        uint level,
        uint width,
        uint height,
    )
    {
        VkBufferImageCopy region;
        region.bufferOffset = bufferOffset;
        region.bufferImageHeight = 0;
        region.bufferRowLength = 0;

        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.mipLevel = level;
        region.imageSubresource.baseArrayLayer = 0;
        region.imageSubresource.layerCount = 1;

        region.imageOffset = VkOffset3D(0, 0, 0);
        region.imageExtent = VkExtent3D(width, height, 1);

        vkCmdCopyBufferToImage(
            buf,
            srcBuffer,
            image,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &region,
        );
    }

    /// Halves the previous level into each following one, leaving them as blit sources
    private void generateMipmaps(VkCommandBuffer buf)
    {
        int width = cast(int) imageExtent.width;
        int height = cast(int) imageExtent.height;

        foreach(level; 1 .. mipLevels)
        {
            addPipelineBarrier(buf, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, level);

            const int nextWidth = width > 1 ? width / 2 : 1;
            const int nextHeight = height > 1 ? height / 2 : 1;

            VkImageBlit blit;
            blit.srcSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            blit.srcSubresource.mipLevel = level - 1;
            blit.srcSubresource.layerCount = 1;
            blit.dstSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            blit.dstSubresource.mipLevel = level;
            blit.dstSubresource.layerCount = 1;
            blit.srcOffsets[1] = VkOffset3D(width, height, 1);
            blit.dstOffsets[1] = VkOffset3D(nextWidth, nextHeight, 1);

            vkCmdBlitImage(
                buf,
                image,
                VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                image,
                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                1,
                &blit,
                VK_FILTER_LINEAR,
            );

            addPipelineBarrier(buf, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, level);

            width = nextWidth;
            height = nextHeight;
        }
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
        case VK_FORMAT_R8G8B8A8_UNORM:
            imageSize = image.width * image.height * 4;
            break;

        case VK_FORMAT_R8G8B8_SRGB:
        case VK_FORMAT_R8G8B8_UNORM:
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

    uint mipLevels = 1;
    for(uint extent = image.width > image.height ? image.width : image.height; extent > 1; extent >>= 1)
        ++mipLevels;

    VkImageCreateInfo imageInfo = {
        imageType: VK_IMAGE_TYPE_2D,
        format: pixelFormat,
        tiling: VK_IMAGE_TILING_OPTIMAL,
        extent: VkExtent3D(
            width: image.width,
            height: image.height,
            depth: 1,
        ),
        mipLevels: mipLevels,
        arrayLayers: 1,
        initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
        usage: VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
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

/// Records and submits an upload of explicit mip levels.
ImageMemory loadImageWithMips(
    LogicalDevice device,
    CommandPool commandPool,
    VkCommandBuffer commandBuf,
    uint width,
    uint height,
    ubyte[][] levels,
    in VkFormat format,
)
{
    ImageMemory ret;
    MemoryBufferMappedToCPU[] staging;

    commandPool.recordOneTimeAndSubmit(commandBuf, (buf) {
        ret = loadImageWithMips(device, buf, width, height, levels, format, staging);
    });

    foreach(buf; staging)
        destroy(buf);

    return ret;
}

/// Records an upload of explicit mip levels; keeps the staging buffer alive.
ImageMemory loadImageWithMips(
    LogicalDevice device,
    VkCommandBuffer buf,
    uint width,
    uint height,
    ubyte[][] levels,
    in VkFormat format,
    ref MemoryBufferMappedToCPU[] staging,
)
{
    size_t totalSize;
    foreach(level; levels)
        totalSize += level.length;

    auto stagingBuffer = device.create!MemoryBufferMappedToCPU(totalSize, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    staging ~= stagingBuffer;

    auto cpuBuf = cast(ubyte[]) stagingBuffer.cpuBuf;
    size_t offset;

    foreach(level; levels)
    {
        cpuBuf[offset .. offset + level.length] = level;
        offset += level.length;
    }

    VkImageCreateInfo imageInfo = {
        imageType: VK_IMAGE_TYPE_2D,
        format: format,
        tiling: VK_IMAGE_TILING_OPTIMAL,
        extent: VkExtent3D(width, height, 1),
        mipLevels: cast(uint) levels.length,
        arrayLayers: 1,
        initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
        usage: VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
        sharingMode: VK_SHARING_MODE_EXCLUSIVE,
        samples: VK_SAMPLE_COUNT_1_BIT,
    };

    auto ret = device.create!ImageMemory(imageInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

    ret.addPipelineBarrier(
        buf,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        0,
        cast(uint) levels.length,
    );

    offset = 0;
    foreach(i, level; levels)
    {
        const levelWidth = width >> i > 0 ? width >> i : 1;
        const levelHeight = height >> i > 0 ? height >> i : 1;

        ret.recordCopyLevel(buf, stagingBuffer.buf, offset, cast(uint) i, levelWidth, levelHeight);
        offset += level.length;
    }

    ret.addPipelineBarrier(
        buf,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        0,
        cast(uint) levels.length,
    );

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
