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

    this(LogicalDevice device, ImageMemory image, ref VkSamplerCreateInfo samplerInfo)
    {
        this.device = device;

        textureImageMemory = image;

        createImageView(imageView, device, VK_FORMAT_R8G8B8A8_SRGB, textureImageMemory.image);

        vkCall(device.device, cast() &samplerInfo, device.alloc, &sampler);
    }

    ~this()
    {
        if(sampler)
            vkDestroySampler(device, sampler, device.alloc);

        if(imageView)
            vkDestroyImageView(device, imageView, device.alloc);
    }
}

auto createFakeTexture1x1(LogicalDevice device)
{
    scope commandPool = device.createCommandPool();
    scope commandBufs = commandPool.allocateBuffers(1);
    scope(exit) commandPool.freeBuffers(commandBufs);

    auto img = createFakeImage1x1(device, commandPool, commandBufs[0]);

    VkSamplerCreateInfo defaultSampler = {
        sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        magFilter: VK_FILTER_LINEAR,
        minFilter: VK_FILTER_LINEAR,
        addressModeU: VK_SAMPLER_ADDRESS_MODE_REPEAT,
        addressModeV: VK_SAMPLER_ADDRESS_MODE_REPEAT,
        addressModeW: VK_SAMPLER_ADDRESS_MODE_REPEAT,
        anisotropyEnable: VK_TRUE,
        maxAnisotropy: 16, //TODO: use vkGetPhysicalDeviceProperties (at least)
        borderColor: VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        unnormalizedCoordinates: VK_FALSE,
        compareEnable: VK_FALSE,
        compareOp: VK_COMPARE_OP_ALWAYS,
        mipmapMode: VK_SAMPLER_MIPMAP_MODE_LINEAR,
    };

    return device.create!Texture(img, defaultSampler);
}
