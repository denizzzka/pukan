module pukan.godot_scene.factory;

import pukan.godot_scene.loader: GodotLoadOptions, loadGodotScene;
import pukan.godot_scene.scene: GodotScene;
import pukan.pbr.factory: PbrFactory;
import pukan.vulkan;
import pukan.vulkan.bindings;
import std.meta: AliasSeq;

class GodotFactory
{
    private alias requirements = AliasSeq!(
        Requirement!(VkPhysicalDeviceFeatures.fragmentStoresAndAtomics),
        Requirement!(VkPhysicalDeviceExtendedDynamicStateFeaturesEXT.extendedDynamicState),
        Requirement!(VkQueueFamilyProperties.queueFlags, VK_QUEUE_GRAPHICS_BIT),
        ImageFormatRequirement!(VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL,
            VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT),
        FormatRequirement!(VK_FORMAT_R8G8B8A8_SRGB,
            VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT
            | VK_FORMAT_FEATURE_BLIT_SRC_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT),
        ImageFormatRequirement!(VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL,
            VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT),
        FormatRequirement!(VK_FORMAT_R8G8B8A8_UNORM,
            VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT
            | VK_FORMAT_FEATURE_BLIT_SRC_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT),
    );

    private PbrFactory pbr;
    GodotLoadOptions loadOptions;

    this(PbrFactory pbr)
    {
        this.pbr = pbr;
    }

    GodotScene create(string filename)
    {
        assert(pbr.device);
        return loadGodotScene(filename, pbr, loadOptions);
    }
}
