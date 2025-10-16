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

    this(Img)(LogicalDevice device, CommandPool commandPool, VkCommandBuffer commandBuf, ref VkSamplerCreateInfo samplerInfo, Img image)
    {
        this.device = device;

        textureImageMemory = loadImageToMemory(device, commandPool, commandBuf, image);

        createImageView(imageView, device, VK_FORMAT_R8G8B8A8_SRGB, textureImageMemory.image);

        vkCall(device.device, cast() &samplerInfo, device.alloc, &sampler);
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
