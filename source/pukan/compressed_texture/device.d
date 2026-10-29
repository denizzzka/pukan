module pukan.compressed_texture.device;

import pukan.compressed_texture.format: CompressedFamily, compressedFormats;
import pukan.vulkan.bindings;
import pukan.vulkan.logical_device: LogicalDevice;

/// Features a sampled compressed image needs at upload time
enum sampledCompressedFeatures = VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT
    | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT
    | VK_FORMAT_FEATURE_TRANSFER_DST_BIT;

/// Whether the device can sample and upload a format
bool formatSupported(LogicalDevice device, VkFormat format)
{
    return device.physicalDevice.supportsFormat(format, sampledCompressedFeatures);
}

/// Whether any format of the family is usable in either color space
bool familySupported(LogicalDevice device, CompressedFamily family)
{
    return familySupported(device, family, false) || familySupported(device, family, true);
}

/// Whether any format of the family is usable in the requested color space
bool familySupported(LogicalDevice device, CompressedFamily family, bool srgb)
{
    foreach(format; compressedFormats)
        if(format.family == family && formatSupported(device, format.vkFormat(srgb)))
            return true;

    return false;
}
