module pukan.vulkan.frame_builder;

import frame_bindings;

//~ import pukan.exceptions;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;
import pukan.vulkan.queue;
import pukan.vulkan.vkobj: OwnedHandles;
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
    }

    ///
    void placeDrawnFrameToGraphicsQueue(Frame frame)
    {
        auto sync = frame.syncPrimitives;

        auto waitStages = cast(uint) VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;

        VkSubmitInfo submitInfo = {
            sType: VK_STRUCTURE_TYPE_SUBMIT_INFO,

            pWaitDstStageMask: &waitStages,

            waitSemaphoreCount: cast(uint) sync.imageAvailableSemaphores.length,
            pWaitSemaphores: sync.imageAvailableSemaphores.ptr,

            commandBufferCount: 1,
            pCommandBuffers: &(frame.commandBuffer()),

            signalSemaphoreCount: cast(uint) sync.renderFinishedSemaphores.length,
            pSignalSemaphores: sync.renderFinishedSemaphores.ptr,
        };

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
        VkDescriptorImageInfo irradiance,
        VkDescriptorImageInfo prefiltered,
        VkDescriptorImageInfo brdfLut,
        VkDescriptorImageInfo sceneColor,
        VkDescriptorImageInfo oitHeads,
        VkDescriptorBufferInfo oitFragments,
        VkDescriptorBufferInfo oitCounter,
        VkDescriptorBufferInfo lights,
        VkDescriptorImageInfo shadowMap,
    )
    {
        buffer = device.create!MemoryBufferMappedToCPU(size, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
        descriptorSet = allocator.allocate();

        VkDescriptorBufferInfo info = { buffer: buffer.buf, offset: 0, range: size };
        VkWriteDescriptorSet[] writes = [
            bufferWriteDescriptor(descriptorSet, FRAME_UNIFORM, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, info),
            imageWriteDescriptor(descriptorSet, FRAME_IRRADIANCE, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, irradiance),
            imageWriteDescriptor(descriptorSet, FRAME_PREFILTERED, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, prefiltered),
            imageWriteDescriptor(descriptorSet, FRAME_BRDF_LUT, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, brdfLut),
            imageWriteDescriptor(descriptorSet, FRAME_SCENE_COLOR, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, sceneColor),
            imageWriteDescriptor(descriptorSet, FRAME_OIT_HEADS, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, oitHeads),
            bufferWriteDescriptor(descriptorSet, FRAME_OIT_FRAGMENTS, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, oitFragments),
            bufferWriteDescriptor(descriptorSet, FRAME_OIT_COUNTER, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, oitCounter),
            bufferWriteDescriptor(descriptorSet, FRAME_LIGHTS, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, lights),
            imageWriteDescriptor(descriptorSet, FRAME_SHADOW_MAP, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, shadowMap),
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
    VkImageView imageView;
    ImageMemory multisampledColor;
    VkImageView multisampledView;
    Texture sceneColor;
    DepthBuf depthBuf;
    VkFramebuffer frameBuffer;
    FrameSet[2] frameSets;
    package SyncFramesInFlight syncPrimitives;
    private OwnedHandles!VkCommandBuffer _commandBuffer;

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
        _commandBuffer = OwnedHandles!VkCommandBuffer(
            fb.commandPool.allocateBuffers(1),
            (VkCommandBuffer[] bufs) { fb.commandPool.freeBuffers(bufs); },
        );

        createImageView(imageView, fb.device, imageFormat, image);
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
            createImageView(multisampledView, fb.device, imageFormat, multisampledColor.image);
        }

        {
            VkImageView[] attachments = samples != VK_SAMPLE_COUNT_1_BIT
                ? [multisampledView, depthBuf.depthView, imageView]
                : [imageView, depthBuf.depthView];

            VkFramebufferCreateInfo frameBufferInfo = {
                sType: VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                renderPass: renderPass,
                attachmentCount: cast(uint) attachments.length,
                pAttachments: attachments.ptr,
                width: imageExtent.width,
                height: imageExtent.height,
                layers: 1,
            };

            vkCreateFramebuffer(fb.device, &frameBufferInfo, fb.device.alloc, &frameBuffer).vkCheck;
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

        if(frameBuffer)
            vkDestroyFramebuffer(fb.device, frameBuffer, fb.device.alloc);

        if(multisampledView)
            vkDestroyImageView(fb.device, multisampledView, fb.device.alloc);

        if(multisampledColor)
            destroy(multisampledColor);

        if(imageView)
            vkDestroyImageView(fb.device, imageView, fb.device.alloc);
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

        imageAvailableSemaphores = [imageAvailable.semaphore.handle];
        renderFinishedSemaphores = [renderFinished.semaphore.handle];
    }
}

void createImageView(ref VkImageView imgView, LogicalDevice device, VkFormat imageFormat, VkImage image, uint levelCount = 1)
{
    VkImageViewCreateInfo cinf = {
        sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        viewType: VK_IMAGE_VIEW_TYPE_2D,
        format: imageFormat,
        components: VkComponentMapping(
            r: VK_COMPONENT_SWIZZLE_IDENTITY,
            g: VK_COMPONENT_SWIZZLE_IDENTITY,
            b: VK_COMPONENT_SWIZZLE_IDENTITY,
            a: VK_COMPONENT_SWIZZLE_IDENTITY,
        ),
        subresourceRange: VkImageSubresourceRange(
            aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
            baseMipLevel: 0,
            levelCount: levelCount,
            baseArrayLayer: 0,
            layerCount: 1,
        ),
        image: image,
    };

    vkCreateImageView(device, &cinf, device.alloc, &imgView).vkCheck;
}

struct DepthBuf
{
    LogicalDevice device;
    ImageMemory depthImage;
    VkImageView depthView;
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
            usage: VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
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

        vkCreateImageView(device, &cinf, device.alloc, &depthView).vkCheck;
    }

    ~this()
    {
        if(depthView)
            vkDestroyImageView(device, depthView, device.alloc);

        destroy(depthImage);
    }
}
