module pukan.gltf.factory;

import pukan.gltf;
import pukan.gltf.loader: GltfLoadOptions;
import pukan.pbr.factory: PbrFactory;
import pukan.vulkan;
import pukan.vulkan.bindings;
import std.meta: AliasSeq;

class GltfFactory
{
    import pukan.gltf.skin_matrices: SkinMatrices;

    private alias requirements = AliasSeq!(
        SkinMatrices.requirements,
        Requirement!(VkPhysicalDeviceFeatures.fragmentStoresAndAtomics),
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
    GltfLoadOptions loadOptions;

    this(PbrFactory pbr, bool computeJointsOnGPU = true)
    {
        this.pbr = pbr;
        this.computeJointsOnGPU = computeJointsOnGPU;
    }

    auto create(string filename)
    {
        assert(pbr.device);

        auto allocator = pbr.createAllocator();

        try
            return loadGlTF2(
                filename,
                allocator,
                pbr.resources.materials,
                pbr.device,
                pbr.pipelineCfgs,
                pbr.resources.fakeTexture,
                pbr.resources.fallbackVertex.buf,
                computeJointsOnGPU,
                loadOptions,
            );
        catch(Exception e)
        {
            e.msg = filename~": "~e.msg;
            //FIXME: use correct exception type
            throw e;
        }
    }
}
