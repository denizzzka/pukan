module pukan.vulkan.textures;

import gamut;
import pukan.exceptions;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;
import std.conv: to;
import std.exception: enforce;

class Texture
{
    LogicalDevice device;
    ImageMemory textureImageMemory;
    VkImageView imageView;
    VkSampler sampler;

    this(LogicalDevice device, CommandPool commandPool, VkCommandBuffer commandBuf)
    {
        this.device = device;

        Image image;
        image.loadFromFile("demo/assets/texture.jpeg", LAYOUT_GAPLESS|LAYOUT_VERT_STRAIGHT|LOAD_ALPHA);

        if (image.isError)
            throw new PukanException(image.errorMessage.to!string);

        enforce!PukanException(image.type == PixelType.rgba8, "Unsupported texture type: "~image.type.to!string);
        enforce!PukanException(image.layers == 1, "Texture image must contain one layer");

        VkDeviceSize imageSize = image.width * image.height * 4 /* rgba */;

        //FIXME: TransferBuffer is used only as src buffer
        scope buf = device.create!MemoryBufferMappedToCPU(imageSize, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        scope(exit) destroy(buf);

        buf.cpuBuf[0 .. $] = image.allPixelsAtOnce;

        {
            VkImageCreateInfo imageInfo = {
                imageType: VK_IMAGE_TYPE_2D,
                format: VK_FORMAT_R8G8B8A8_SRGB,
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

            textureImageMemory = device.create!ImageMemory(imageInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        }

        // TODO: fix ugly args naming
        textureImageMemory.copyFromBuffer(commandPool, commandBuf, buf.buf);

        createImageView(imageView, device, VK_FORMAT_R8G8B8A8_SRGB, textureImageMemory.image);

        VkSamplerCreateInfo samplerInfo;
        {
            samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
            samplerInfo.magFilter = VK_FILTER_LINEAR;
            samplerInfo.minFilter = VK_FILTER_LINEAR;
            samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;
            samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
            samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
            samplerInfo.anisotropyEnable = VK_TRUE;
            samplerInfo.maxAnisotropy = 16; //TODO: use vkGetPhysicalDeviceProperties (at least)
            samplerInfo.borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK;
            samplerInfo.unnormalizedCoordinates = VK_FALSE;
            samplerInfo.compareEnable = VK_FALSE;
            samplerInfo.compareOp = VK_COMPARE_OP_ALWAYS;
            samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
        }

        vkCall(device.device, &samplerInfo, device.backend.allocator, &sampler);
    }

    ~this()
    {
        if(sampler)
            vkDestroySampler(device, sampler, device.backend.allocator);

        if(imageView)
            vkDestroyImageView(device, imageView, device.backend.allocator);

        destroy(textureImageMemory);
    }
}
