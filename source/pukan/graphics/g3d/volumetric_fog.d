module pukan.graphics.g3d.volumetric_fog;

import dlib.math: Vector3f, Vector4f;
import pukan.graphics.common.shaders: shaderStage;
import pukan.vulkan.bindings;
import pukan.vulkan.descriptors: bufferWriteDescriptor, imageWriteDescriptor;
import pukan.vulkan.helpers: vkCheck;
import pukan.vulkan.image: ImageMemory, transitionImageLayout;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: MemoryBufferMappedToCPU;
import pukan.vulkan.pipelines: PipelineFactory, PipelineKey;
import pukan.vulkan.resources.vkobj: VkObj;
import std.algorithm: min;

/// Slices the froxel volume is split into along the view ray;
/// FOG_SLICE_COUNT in fog.glsl must match
enum fogSlices = 64;
/// Froxels across the screen, the same count at every window size
enum fogFroxelsX = 160;
enum fogFroxelsY = 90;
/// Fog volumes one frame may describe
enum maxFogVolumes = 32;
/// Closest distance the slices cover, in metres
enum fogNear = 0.1f;

/// Global fog of a scene, Godot's Environment.volumetric_fog_*
struct VolumetricFogSettings
{
    bool enabled;
    /// Extinction per metre, uniform over the scene
    float density = 0.01f;
    /// Fraction of the light the medium scatters back
    Vector3f albedo = Vector3f(1.0f, 1.0f, 1.0f);
    /// Light the medium gives off, times `emissionEnergy`
    Vector3f emission = Vector3f(0.0f, 0.0f, 0.0f);
    float emissionEnergy = 0.0f;
    /// Positive values scatter forward, negative back towards the light
    float anisotropy = 0.0f;
    /// Farthest distance the slices cover
    float length = 64.0f;
    /// How much of the sky the fog covers; not applied yet
    float skyAffect = 0.0f;
    /// Seconds the cloud noise drifts with; the host advances it
    float animationTime = 0.0f;
}

/// Shape of a local fog volume
enum FogVolumeShape: uint
{
    box,
    ellipsoid,
}

/// Denser fog inside a box or an ellipsoid
struct FogVolume
{
    FogVolumeShape shape;
    Vector3f center;
    Vector3f halfExtents = Vector3f(1.0f, 1.0f, 1.0f);
    /// Extinction per metre inside the shape
    float density = 0.1f;
    Vector3f albedo = Vector3f(1.0f, 1.0f, 1.0f);
    Vector3f emission = Vector3f(0.0f, 0.0f, 0.0f);
    float emissionEnergy = 0.0f;
    /// Fraction of the volume the density fades over at the edge
    float edgeFade = 0.1f;
    /// How much the cloud noise breaks the shape up, zero keeps it smooth
    float noise = 0.0f;
    /// Metres between the noise features
    float noiseScale = 1.0f;
}

/// Mirrors the FogVolume struct in fog.glsl
private struct FogVolumeGpu
{
    Vector4f centerShape;
    Vector4f halfExtentsDensity;
    Vector4f albedoEmission;
    Vector4f emissionEdge;
    Vector4f noiseScale;
}

static assert(FogVolumeGpu.sizeof == 80);

/// Pipelines of the two fog kernels; the volumes themselves live in a frame
final class VolumetricFog
{
    private LogicalDevice device;
    private PipelineFactory pipelines;
    private PipelineKey injectKey;
    private PipelineKey integrateKey;
    private VkDescriptorSetLayout injectSetLayout;
    private VkDescriptorSetLayout integrateSetLayout;
    private VkPipelineLayout injectLayout;
    private VkPipelineLayout integrateLayout;
    private VkPipeline injectPipeline;
    private VkPipeline integratePipeline;
    private VkSampler sampler;

    private static struct InjectPush
    {
        uint froxelsX;
        uint froxelsY;
        uint froxelsZ;
        uint volumeCount;
        float time;
    }

    private static struct IntegratePush
    {
        uint froxelsX;
        uint froxelsY;
        uint slices;
    }

    this(LogicalDevice device, PipelineFactory pipelines)
    {
        this.device = device;
        this.pipelines = pipelines;

        static VkDescriptorSetLayoutBinding binding(uint index, VkDescriptorType type)
        {
            return VkDescriptorSetLayoutBinding(
                binding: index,
                descriptorType: type,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
            );
        }

        auto injectBindings = [
            binding(0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE),
            binding(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER),
        ];
        auto inject = pipelines.declareCompute(shaderStage!"fog_inject.spv"(
            VK_SHADER_STAGE_COMPUTE_BIT,
            injectBindings,
            VkPushConstantRange(
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
                offset: 0,
                size: InjectPush.sizeof,
            ),
        ));
        injectKey = inject.key;
        injectSetLayout = inject.setLayout;
        injectLayout = inject.pipelineLayout;

        auto integrateBindings = [
            binding(0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE),
        ];
        auto integrate = pipelines.declareCompute(shaderStage!"fog_integrate.spv"(
            VK_SHADER_STAGE_COMPUTE_BIT,
            integrateBindings,
            VkPushConstantRange(
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
                offset: 0,
                size: IntegratePush.sizeof,
            ),
        ));
        integrateKey = integrate.key;
        integrateSetLayout = integrate.setLayout;
        integrateLayout = integrate.pipelineLayout;

        VkSamplerCreateInfo samplerInfo = {
            sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            magFilter: VK_FILTER_LINEAR,
            minFilter: VK_FILTER_LINEAR,
            mipmapMode: VK_SAMPLER_MIPMAP_MODE_NEAREST,
            addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            compareEnable: VK_FALSE,
            compareOp: VK_COMPARE_OP_ALWAYS,
            minLod: 0,
            maxLod: VK_LOD_CLAMP_NONE,
        };

        vkCreateSampler(device.device, &samplerInfo, device.alloc, &sampler).vkCheck;
    }

    ~this()
    {
        if(sampler)
        {
            vkDestroySampler(device, sampler, device.alloc);
            sampler = null;
        }
    }

    /// Resources of one frame in flight
    VolumetricFogFrame createFrame()
    {
        auto frame = new VolumetricFogFrame(device, this);
        return frame;
    }

    /// Sampler the frame set reads the volume with
    @property VkSampler readSampler() => sampler;

    /// Fills a frame's volume with the fog at a frame set's camera
    void record(
        VkCommandBuffer buf,
        VolumetricFogFrame frame,
        VkDescriptorSet frameSet,
        in VolumetricFogSettings settings,
        in FogVolume[] volumes,
    )
    {
        if(frame is null)
            return;

        frame.uploadVolumes(volumes);

        if(injectPipeline is null)
        {
            auto cfg = pipelines.acquireCompute(injectKey);
            injectPipeline = cfg.pipeline;
            injectLayout = cfg.pipelineLayout;

            cfg = pipelines.acquireCompute(integrateKey);
            integratePipeline = cfg.pipeline;
            integrateLayout = cfg.pipelineLayout;
        }

        const computeStage = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
        const shaderRead = VK_ACCESS_SHADER_READ_BIT;
        const shaderWrite = VK_ACCESS_SHADER_WRITE_BIT;

        // The kernel writes the volume and reads it back, so it stays general
        transitionImageLayout(
            buf, frame.image.image,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_GENERAL,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, shaderRead,
            computeStage, shaderWrite,
        );

        {
            auto sets = [frame.injectSet, frameSet];

            vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_COMPUTE, injectPipeline);
            vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_COMPUTE, injectLayout, 0, 2, sets.ptr, 0, null);

            const push = InjectPush(fogFroxelsX, fogFroxelsY, fogSlices, frame.volumeCount, settings.animationTime);
            vkCmdPushConstants(buf, injectLayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, push.sizeof, &push);

            enum group = 8;
            vkCmdDispatch(
                buf,
                (fogFroxelsX + group - 1) / group,
                (fogFroxelsY + group - 1) / group,
                fogSlices,
            );
        }

        transitionImageLayout(
            buf, frame.image.image,
            VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_GENERAL,
            computeStage, shaderWrite,
            computeStage, shaderRead,
        );

        {
            auto sets = [frame.integrateSet, frameSet];

            vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_COMPUTE, integratePipeline);
            vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_COMPUTE, integrateLayout, 0, 2, sets.ptr, 0, null);

            const push = IntegratePush(fogFroxelsX, fogFroxelsY, fogSlices);
            vkCmdPushConstants(buf, integrateLayout, VK_SHADER_STAGE_COMPUTE_BIT, 0, push.sizeof, &push);

            enum group = 8;
            vkCmdDispatch(buf, (fogFroxelsX + group - 1) / group, (fogFroxelsY + group - 1) / group, 1);
        }

        transitionImageLayout(
            buf, frame.image.image,
            VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            computeStage, shaderWrite,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, shaderRead,
        );
    }
}

/// One frame's froxel volume, its volume list and the sets the kernels bind
final class VolumetricFogFrame
{
    private LogicalDevice device;
    private ImageMemory image;
    private VkObj!VkImageView viewObj;
    private VkObj!VkDescriptorPool pool;
    private VkDescriptorSet injectSet;
    private VkDescriptorSet integrateSet;
    private MemoryBufferMappedToCPU volumeBuffer;
    /// Volumes the buffer holds, as record handed them over
    uint volumeCount;

    private this(LogicalDevice device, VolumetricFog owner)
    {
        this.device = device;

        VkImageCreateInfo info = {
            sType: VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            imageType: VK_IMAGE_TYPE_3D,
            format: VK_FORMAT_R16G16B16A16_SFLOAT,
            tiling: VK_IMAGE_TILING_OPTIMAL,
            extent: VkExtent3D(fogFroxelsX, fogFroxelsY, fogSlices),
            mipLevels: 1,
            arrayLayers: 1,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usage: VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
            samples: VK_SAMPLE_COUNT_1_BIT,
        };

        image = device.create!ImageMemory(info, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        VkImageViewCreateInfo viewInfo = {
            sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            viewType: VK_IMAGE_VIEW_TYPE_3D,
            format: VK_FORMAT_R16G16B16A16_SFLOAT,
            subresourceRange: VkImageSubresourceRange(
                aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
                baseMipLevel: 0,
                levelCount: 1,
                baseArrayLayer: 0,
                layerCount: 1,
            ),
            image: image.image,
        };
        viewObj = VkObj!VkImageView(device.releaseQueue, viewInfo);

        volumeBuffer = device.create!MemoryBufferMappedToCPU(
            maxFogVolumes * FogVolumeGpu.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );

        pool = VkObj!VkDescriptorPool(
            device.createDescriptorPool(
                [
                    VkDescriptorSetLayoutBinding(
                        binding: 0,
                        descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
                        descriptorCount: 1,
                        stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
                    ),
                    VkDescriptorSetLayoutBinding(
                        binding: 1,
                        descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                        descriptorCount: 1,
                        stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
                    ),
                ],
                2,
            ),
            device.releaseQueue,
        );

        VkDescriptorBufferInfo volumes = VkDescriptorBufferInfo(
            buffer: volumeBuffer.buf,
            offset: 0,
            range: VK_WHOLE_SIZE,
        );

        injectSet = device.allocateDescriptorSet(pool.vk, owner.injectSetLayout);
        {
            auto target = VkDescriptorImageInfo(
                imageLayout: VK_IMAGE_LAYOUT_GENERAL,
                imageView: viewObj.vk,
            );

            scope writes = [
                imageWriteDescriptor(injectSet, 0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, target),
                bufferWriteDescriptor(injectSet, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, volumes),
            ];
            device.updateDescriptorSets(writes);
        }

        integrateSet = device.allocateDescriptorSet(pool.vk, owner.integrateSetLayout);
        {
            auto target = VkDescriptorImageInfo(
                imageLayout: VK_IMAGE_LAYOUT_GENERAL,
                imageView: viewObj.vk,
            );

            scope writes = [
                imageWriteDescriptor(integrateSet, 0, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, target),
            ];
            device.updateDescriptorSets(writes);
        }

        // Frames sample the volume before any kernel wrote it
        auto commandPool = device.createCommandPool();
        auto buffers = commandPool.allocateBuffers(1);
        commandPool.recordOneTimeAndSubmit(buffers[0], (VkCommandBuffer buf) {
            transitionImageLayout(
                buf, image.image,
                VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, 0,
                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_ACCESS_SHADER_READ_BIT,
            );
        });
        destroy(commandPool);
    }

    ~this()
    {
        if(volumeBuffer)
        {
            destroy(volumeBuffer);
            volumeBuffer = null;
        }

        if(viewObj.isAlive())
            destroy(viewObj);

        if(image)
        {
            destroy(image);
            image = null;
        }
    }

    /// The volume as the frame set samples it
    VkDescriptorImageInfo imageInfo()
    {
        return VkDescriptorImageInfo(
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            imageView: viewObj.vk,
        );
    }

    /// Packs a scene's volumes for the injection kernel; extras are dropped
    private void uploadVolumes(in FogVolume[] volumes)
    {
        const count = min(volumes.length, maxFogVolumes);
        auto packed = cast(FogVolumeGpu[]) volumeBuffer.cpuBuf[0 .. count * FogVolumeGpu.sizeof];

        foreach(i; 0 .. count)
        {
            const volume = volumes[i];

            packed[i] = FogVolumeGpu(
                Vector4f(volume.center.x, volume.center.y, volume.center.z, cast(float) volume.shape),
                Vector4f(volume.halfExtents.x, volume.halfExtents.y, volume.halfExtents.z, volume.density),
                Vector4f(volume.albedo.x, volume.albedo.y, volume.albedo.z, volume.emissionEnergy),
                Vector4f(volume.emission.x, volume.emission.y, volume.emission.z, volume.edgeFade),
                Vector4f(volume.noise, volume.noiseScale, 0.0f, 0.0f),
            );
        }

        volumeCount = cast(uint) count;
    }
}

unittest
{
    // Settings mirror Godot's defaults for an environment that enables fog
    VolumetricFogSettings settings;
    assert(!settings.enabled);
    assert(settings.length == 64.0f);
    assert(settings.anisotropy == 0.0f);

    // The volume a level may add stays inside the packing the kernel reads
    FogVolume volume;
    assert(volume.shape == FogVolumeShape.box);
    assert(volume.halfExtents == Vector3f(1.0f, 1.0f, 1.0f));
    assert(FogVolumeGpu.sizeof == 80);
}
