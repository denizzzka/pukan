module pukan.screenshot;

import dlib.image: ImageRGBA8, savePNG;
import pukan.exceptions: PukanException;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.image: transitionImageLayout;
import std.conv: to;

/// Copies the last rendered frame to a PNG on the CPU
final class Screenshot
{
    private LogicalDevice device;
    private MemoryBufferMappedToCPU buffer;
    private uint width;
    private uint height;
    private VkFormat format;

    this(LogicalDevice device, uint width, uint height, VkFormat format)
    {
        this.device = device;
        this.width = width;
        this.height = height;
        this.format = format;

        buffer = device.create!MemoryBufferMappedToCPU(
            cast(size_t) width * height * 4,
            VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        );
    }

    ~this()
    {
        if(buffer)
            destroy(buffer);
    }

    /// Records the swapchain image copy; call before the image is presented
    void record(VkCommandBuffer cb, VkImage image)
    {
        transitionImageLayout(
            cb, image,
            VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT,
        );

        VkBufferImageCopy region;
        region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.mipLevel = 0;
        region.imageSubresource.baseArrayLayer = 0;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = VkExtent3D(width, height, 1);

        vkCmdCopyImageToBuffer(
            cb,
            image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            buffer.buf,
            1, &region,
        );

        transitionImageLayout(
            cb, image,
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT,
            VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        );
    }

    /// Writes the copied frame; the device must be idle
    void save(string path)
    {
        auto image = new ImageRGBA8(width, height);
        auto source = cast(const(ubyte)[]) buffer.cpuBuf;
        auto target = image.data;

        switch(format)
        {
            case VK_FORMAT_B8G8R8A8_SRGB:
            case VK_FORMAT_B8G8R8A8_UNORM:
                foreach(i; 0 .. width * height)
                {
                    target[i * 4 + 0] = source[i * 4 + 2];
                    target[i * 4 + 1] = source[i * 4 + 1];
                    target[i * 4 + 2] = source[i * 4 + 0];
                    target[i * 4 + 3] = source[i * 4 + 3] ? source[i * 4 + 3] : 255;
                }
                break;

            case VK_FORMAT_R8G8B8A8_SRGB:
            case VK_FORMAT_R8G8B8A8_UNORM:
                foreach(i; 0 .. width * height)
                {
                    target[i * 4 + 0] = source[i * 4 + 0];
                    target[i * 4 + 1] = source[i * 4 + 1];
                    target[i * 4 + 2] = source[i * 4 + 2];
                    target[i * 4 + 3] = source[i * 4 + 3] ? source[i * 4 + 3] : 255;
                }
                break;

            default:
                throw new PukanException("unsupported swapchain format for a screenshot: " ~ format.to!string);
        }

        savePNG(image, path);
    }
}
