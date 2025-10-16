module pukan.vulkan.textures;

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

    this(Img)(LogicalDevice device, CommandPool commandPool, VkCommandBuffer commandBuf, Img image)
    {
        this.device = device;

        textureImageMemory = loadImageToMemory(device, commandPool, commandBuf, image);

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

        vkCall(device.device, &samplerInfo, device.alloc, &sampler);
    }

    ~this()
    {
        if(sampler)
            vkDestroySampler(device, sampler, device.alloc);

        if(imageView)
            vkDestroyImageView(device, imageView, device.alloc);

        destroy(textureImageMemory);
    }
}
