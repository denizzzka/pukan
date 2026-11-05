module pukan.vulkan.frame_builder;

import pukan.vulkan.commands: CommandBuffers, CommandPool;
import pukan.vulkan.frame_bindings: FrameBindings;
import pukan.vulkan.descriptors: bufferWriteDescriptor, imageWriteDescriptor;
import pukan.vulkan.image: ImageMemory, identityComponentMapping;
import pukan.vulkan.logical_device: LogicalDevice, Semaphore;
import pukan.vulkan.memory: MemoryBufferMappedToCPU;
import pukan.vulkan.pipelines: DescriptorAllocator;
import pukan.vulkan.requirements: ImageFormatRequirement;
import pukan.vulkan.textures: Texture;

//~ import pukan.vulkan.exceptions;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;
import pukan.vulkan.queue;
import pukan.vulkan.resources.vkobj: VkObj;
import std.meta: AliasSeq;

// This class should gradually become shared thread-safe
class FrameBuilder
{
    private alias requirements = AliasSeq!(
        ImageFormatRequirement!(VK_FORMAT_D24_UNORM_S8_UINT, VK_IMAGE_TYPE_2D,
            VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT),
        ImageFormatRequirement!(VK_FORMAT_D24_UNORM_S8_UINT, VK_IMAGE_TYPE_2D,
            VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            0, VkExtent3D(1, 1, 1), 1, 1, VK_SAMPLE_COUNT_4_BIT),
        ImageFormatRequirement!(VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_TYPE_2D,
            VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            0, VkExtent3D(1, 1, 1), 1, 1, VK_SAMPLE_COUNT_4_BIT),
        ImageFormatRequirement!(VK_FORMAT_B8G8R8A8_SRGB, VK_IMAGE_TYPE_2D,
            VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            0, VkExtent3D(1, 1, 1), 1, 1, VK_SAMPLE_COUNT_4_BIT),
    );

    LogicalDevice device;
    private Queue graphicsQueue;
    /* TODO:private */ CommandPool commandPool;

    this(LogicalDevice dev, size_t uniformBufferSize)
    {
        device = dev;
        //TODO: implement method to acquire graphics queue
        graphicsQueue = device.createSyncQueue;
        commandPool = device.createCommandPool();
    }

    ~this()
    {
        destroy(commandPool);

        if(graphicsQueue)
            destroy(graphicsQueue);
    }

    ///
    void placeDrawnFrameToGraphicsQueue(Frame frame, bool waitForImage = true)
    {
        auto sync = frame.syncPrimitives;

        auto waitStages = cast(uint) VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;

        VkSubmitInfo submitInfo = {
            sType: VK_STRUCTURE_TYPE_SUBMIT_INFO,

            pWaitDstStageMask: &waitStages,
        };

        if(waitForImage)
        {
            submitInfo.waitSemaphoreCount = cast(uint) sync.imageAvailableSemaphores.length;
            submitInfo.pWaitSemaphores = sync.imageAvailableSemaphores.ptr;
            submitInfo.signalSemaphoreCount = cast(uint) sync.renderFinishedSemaphores.length;
            submitInfo.pSignalSemaphores = sync.renderFinishedSemaphores.ptr;
        }

        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &(frame.commandBuffer());

        graphicsQueue.syncSubmit(submitInfo);
    }
}

final class FrameSet
{
    private MemoryBufferMappedToCPU buffer;
    VkDescriptorSet descriptorSet;

    this(
        LogicalDevice device,
        DescriptorAllocator allocator,
        size_t size,
        FrameBindings bindings,
        VkDescriptorImageInfo irradiance,
        VkDescriptorImageInfo prefiltered,
        VkDescriptorImageInfo brdfLut,
        VkDescriptorImageInfo sceneColor,
        VkDescriptorImageInfo oitHeads,
        VkDescriptorBufferInfo oitFragments,
        VkDescriptorBufferInfo oitCounter,
        VkDescriptorBufferInfo lights,
        VkDescriptorImageInfo shadowMap,
        VkDescriptorImageInfo shadowMap1,
        VkDescriptorImageInfo shadowMap2,
        VkDescriptorImageInfo sceneDepth,
        VkDescriptorImageInfo depthMS,
        VkDescriptorImageInfo spotShadows,
    )
    {
        buffer = device.create!MemoryBufferMappedToCPU(size, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
        descriptorSet = allocator.allocate();

        VkDescriptorBufferInfo info = { buffer: buffer.buf, offset: 0, range: size };
        VkWriteDescriptorSet[] writes = [
            bufferWriteDescriptor(descriptorSet, bindings.uniform, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, info),
            imageWriteDescriptor(descriptorSet, bindings.irradiance, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, irradiance),
            imageWriteDescriptor(descriptorSet, bindings.prefiltered, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, prefiltered),
            imageWriteDescriptor(descriptorSet, bindings.brdfLut, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, brdfLut),
            imageWriteDescriptor(descriptorSet, bindings.sceneColor, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, sceneColor),
            imageWriteDescriptor(descriptorSet, bindings.oitHeads, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, oitHeads),
            bufferWriteDescriptor(descriptorSet, bindings.oitFragments, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, oitFragments),
            bufferWriteDescriptor(descriptorSet, bindings.oitCounter, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, oitCounter),
            bufferWriteDescriptor(descriptorSet, bindings.lights, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, lights),
            imageWriteDescriptor(descriptorSet, bindings.shadowMap, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, shadowMap),
            imageWriteDescriptor(descriptorSet, bindings.shadowMap1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, shadowMap1),
            imageWriteDescriptor(descriptorSet, bindings.shadowMap2, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, shadowMap2),
            imageWriteDescriptor(descriptorSet, bindings.sceneDepth, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, sceneDepth),
            imageWriteDescriptor(descriptorSet, bindings.depthMS, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, depthMS),
            imageWriteDescriptor(descriptorSet, bindings.spotShadows, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, spotShadows),
        ];
        device.updateDescriptorSets(writes);
    }

    ~this()
    {
        if(buffer)
            destroy(buffer);
    }

    void update(T)(in T data)
    {
        import core.stdc.string: memcpy;

        memcpy(buffer.cpuBuf.ptr, &data, T.sizeof);
    }
}

class Frame
{
    FrameBuilder fb;
    VkImage image;
    private VkObj!VkImageView imageViewObj;
    ImageMemory multisampledColor;
    private VkObj!VkImageView multisampledViewObj;
    Texture sceneColor;
    DepthBuf depthBuf;
    private VkObj!VkFramebuffer frameBufferObj;

    @property ref VkImageView imageView() => imageViewObj.vk;
    @property ref VkImageView multisampledView() => multisampledViewObj.vk;
    @property ref VkFramebuffer frameBuffer() => frameBufferObj.vk;
    FrameSet[2] frameSets;
    package SyncFramesInFlight syncPrimitives;
    private CommandBuffers _commandBuffer;

    ref VkCommandBuffer commandBuffer() => _commandBuffer[0];

    this(
        FrameBuilder fb,
        VkImage image,
        VkExtent2D imageExtent,
        VkFormat imageFormat,
        VkRenderPass renderPass,
        VkSampleCountFlagBits samples,
    )
    {
        this.fb = fb;
        this.image = image;
        syncPrimitives = new SyncFramesInFlight(fb);
        _commandBuffer = new CommandBuffers(
            fb.device.releaseQueue,
            fb.commandPool.commandPool.vk,
            fb.commandPool.allocateBuffers(1),
        );

        imageViewObj = createImageView(fb.device, imageFormat, image);
        depthBuf = DepthBuf(fb.device, imageExtent, samples);

        if(samples != VK_SAMPLE_COUNT_1_BIT)
        {
            VkImageCreateInfo cinf = {
                imageType: VK_IMAGE_TYPE_2D,
                format: imageFormat,
                tiling: VK_IMAGE_TILING_OPTIMAL,
                extent: VkExtent3D(imageExtent.width, imageExtent.height, 1),
                mipLevels: 1,
                arrayLayers: 1,
                initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
                usage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
                sharingMode: VK_SHARING_MODE_EXCLUSIVE,
                samples: samples,
            };

            multisampledColor = fb.device.create!ImageMemory(cinf, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
            multisampledViewObj = createImageView(fb.device, imageFormat, multisampledColor.image);
        }

        {
            VkImageView[] attachments = samples != VK_SAMPLE_COUNT_1_BIT
                ? [multisampledView, depthBuf.depthView, imageView]
                : [imageView, depthBuf.depthView];

            VkFramebufferCreateInfo frameBufferInfo = {
                renderPass: renderPass,
                attachmentCount: cast(uint) attachments.length,
                pAttachments: attachments.ptr,
                width: imageExtent.width,
                height: imageExtent.height,
                layers: 1,
            };

            frameBufferObj = VkObj!VkFramebuffer(fb.device.releaseQueue, frameBufferInfo);
        }
    }

    ~this()
    {
        foreach(ref set; frameSets)
            if(set)
                destroy(set);

        if(syncPrimitives)
            destroy(syncPrimitives);

        if(sceneColor)
            destroy(sceneColor);

        if(multisampledColor)
            destroy(multisampledColor);

        // The pool outlives the commands that read them, so the queue frees them
        if(_commandBuffer)
            fb.device.releaseQueue.retireHolder(_commandBuffer);
    }
}

//TODO: struct?
class SyncFramesInFlight
{
    Semaphore imageAvailable;
    Semaphore renderFinished;

    VkSemaphore[] imageAvailableSemaphores;
    VkSemaphore[] renderFinishedSemaphores;

    private this(FrameBuilder fb)
    {
        imageAvailable = fb.device.create!Semaphore;
        renderFinished = fb.device.create!Semaphore;

        imageAvailableSemaphores = [imageAvailable.semaphore.vk];
        renderFinishedSemaphores = [renderFinished.semaphore.vk];
    }

    ~this()
    {
        if(imageAvailable)
            destroy(imageAvailable);

        if(renderFinished)
            destroy(renderFinished);
    }
}

VkObj!VkImageView createImageView(LogicalDevice device, VkFormat imageFormat, VkImage image,
    uint levelCount = 1, VkComponentMapping components = identityComponentMapping)
{
    VkImageViewCreateInfo cinf = {
        sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        viewType: VK_IMAGE_VIEW_TYPE_2D,
        format: imageFormat,
        components: components,
        subresourceRange: VkImageSubresourceRange(
            aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
            baseMipLevel: 0,
            levelCount: levelCount,
            baseArrayLayer: 0,
            layerCount: 1,
        ),
        image: image,
    };

    return VkObj!VkImageView(device.releaseQueue, cinf);
}

struct DepthBuf
{
    LogicalDevice device;
    ImageMemory depthImage;
    private VkObj!VkImageView depthViewObj;

    @property ref VkImageView depthView() => depthViewObj.vk;
    //TODO: autodetection need
    enum format = VK_FORMAT_D24_UNORM_S8_UINT;

    this(LogicalDevice dev, VkExtent2D imageExtent, VkSampleCountFlagBits samples = VK_SAMPLE_COUNT_1_BIT)
    {
        device = dev;

        VkImageCreateInfo imageInfo = {
            imageType: VK_IMAGE_TYPE_2D,
            format: format,
            tiling: VK_IMAGE_TILING_OPTIMAL,
            extent: VkExtent3D(imageExtent.width, imageExtent.height, 1),
            mipLevels: 1,
            arrayLayers: 1,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usage: VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
            samples: samples,
        };

        depthImage = device.create!ImageMemory(imageInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        VkImageViewCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            viewType: VK_IMAGE_VIEW_TYPE_2D,
            format: format,
            subresourceRange: VkImageSubresourceRange(
                aspectMask: VK_IMAGE_ASPECT_DEPTH_BIT,
                baseMipLevel: 0,
                levelCount: 1,
                baseArrayLayer: 0,
                layerCount: 1,
            ),
            image: depthImage,
        };

        depthViewObj = VkObj!VkImageView(device.releaseQueue, cinf);
    }

    ~this()
    {
        destroy(depthImage);
    }
}
