module pukan.gltf.factory;

import pukan.gltf;
import pukan.gltf.loader: GltfAsset, GltfLoadOptions, createGltfInstance, loadGltfAsset;
import pukan.pbr.factory: PbrFactory;
import pukan.vulkan;
import pukan.vulkan.bindings;
import std.conv: to;
import std.meta: AliasSeq;

class GltfFactory
{
    import pukan.gltf.skin_matrices: SkinMatrices;

    private alias requirements = AliasSeq!(
        SkinMatrices.requirements,
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
    private immutable bool computeJointsOnGPU;
    private GltfAsset[string] assetCache;
    GltfLoadOptions loadOptions;

    this(PbrFactory pbr, bool computeJointsOnGPU = true)
    {
        this.pbr = pbr;
        this.computeJointsOnGPU = computeJointsOnGPU;
    }

    auto create(string filename)
    {
        assert(pbr.device);

        const key = filename ~ "|" ~ loadOptions.extensions.to!string ~
            "|" ~ loadOptions.modeOverride.to!string;

        GltfAsset asset;

        if(auto cached = key in assetCache)
            asset = *cached;
        else
        {
            try
                asset = loadGltfAsset(filename, pbr.device, loadOptions);
            catch(Exception e)
            {
                e.msg = filename ~ ": " ~ e.msg;
                throw e;
            }

            assetCache[key] = asset;
        }

        auto allocator = pbr.createAllocator();

        return createGltfInstance(
            asset,
            allocator,
            pbr.resources.materials,
            pbr.device,
            pbr.pipelineCfgs,
            pbr.resources.fakeTexture,
            pbr.resources.fallbackVertex.buf,
            computeJointsOnGPU,
            loadOptions,
        );
    }

    /// Number of parsed glTF files currently shared by instances
    size_t cachedAssetCount() const => assetCache.length;

    /// Releases cached file content before the device is destroyed
    void destroyAssets()
    {
        foreach(ref asset; assetCache)
            destroy(asset);

        assetCache = null;
    }

    ~this()
    {
        destroyAssets();
    }
}
