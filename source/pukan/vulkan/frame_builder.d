module pukan.vulkan.frame_builder;

//~ import pukan.exceptions;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;
import pukan.vulkan.queue;

// This class should gradually become shared thread-safe
class FrameBuilder
{
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

class Frame
{
    FrameBuilder fb;
    VkImageView imageView;
    DepthBuf depthBuf;
    VkFramebuffer frameBuffer;
    package SyncFramesInFlight syncPrimitives;
    VkCommandBuffer[] _commandBuffer; // array used for distinction if not initialized

    ref VkCommandBuffer commandBuffer() => _commandBuffer[0];

    this(FrameBuilder fb, VkImage image, VkExtent2D imageExtent, VkFormat imageFormat, VkRenderPass renderPass)
    {
        this.fb = fb;
        syncPrimitives = new SyncFramesInFlight(fb);
        _commandBuffer = fb.commandPool.allocateBuffers(1);

        createImageView(imageView, fb.device, imageFormat, image);
        depthBuf = DepthBuf(fb.device, imageExtent);

        {
            VkImageView[2] attachments = [
                imageView,
                depthBuf.depthView,
            ];

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
        fb.commandPool.freeBuffers(_commandBuffer);

        if(syncPrimitives)
            destroy(syncPrimitives);

        if(frameBuffer)
            vkDestroyFramebuffer(fb.device, frameBuffer, fb.device.alloc);

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

        imageAvailableSemaphores = [imageAvailable.semaphore];
        renderFinishedSemaphores = [renderFinished.semaphore];
    }
}

void createImageView(ref VkImageView imgView, LogicalDevice device, VkFormat imageFormat, VkImage image)
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
            levelCount: 1,
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

    this(LogicalDevice dev, VkExtent2D imageExtent)
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
            samples: VK_SAMPLE_COUNT_1_BIT,
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
