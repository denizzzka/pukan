module pukan.vulkan.frame_builder;

//~ import pukan.exceptions;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;
import pukan.vulkan.queue;

class FrameBuilder
{
    LogicalDevice device;
    private Queue graphicsQueue;
    TransferBuffer uniformBuffer;
    /* TODO:private */ CommandPool commandPool;

    this(LogicalDevice dev)
    {
        device = dev;
        //TODO: implement method to acquire graphics queue
        graphicsQueue = device.createSyncQueue;
        commandPool = device.createCommandPool();

        // FIXME: bad idea to allocate a memory buffer only for one uniform buffer,
        // need to allocate more memory then divide it into pieces
        uniformBuffer = device.create!TransferBuffer(UniformBufferObject.sizeof, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
    }

    ~this()
    {
        destroy(commandPool);
        destroy(uniformBuffer);
    }

    /// Submit frame after draw
    void queueSubmit(Frame frame)
    {
        auto sync = frame.syncPrimitives;

        auto waitStages = cast(uint) VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;

        VkSubmitInfo submitInfo = {
            sType: VK_STRUCTURE_TYPE_SUBMIT_INFO,

            pWaitDstStageMask: &waitStages,

            waitSemaphoreCount: cast(uint) sync.imageAvailableSemaphores.length,
            pWaitSemaphores: sync.imageAvailableSemaphores.ptr,

            commandBufferCount: 1,
            pCommandBuffers: &frame.commandBuffer,

            signalSemaphoreCount: cast(uint) sync.renderFinishedSemaphores.length,
            pSignalSemaphores: sync.renderFinishedSemaphores.ptr,
        };

        graphicsQueue.syncSubmit(submitInfo);
    }
}

class Frame
{
    LogicalDevice device; //TODO: store frame builder instead
    VkImageView imageView;
    DepthBuf depthBuf;
    VkFramebuffer frameBuffer;
    SyncFramesInFlight syncPrimitives;
    VkCommandBuffer commandBuffer;

    this(FrameBuilder fb, VkImage image, VkExtent2D imageExtent, VkFormat imageFormat, VkRenderPass renderPass)
    {
        device = fb.device;
        syncPrimitives = new SyncFramesInFlight(fb);
        commandBuffer = fb.commandPool.allocateBuffers(1)[0];

        createImageView(imageView, device, imageFormat, image);
        depthBuf = DepthBuf(device, imageExtent);

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

            vkCreateFramebuffer(device, &frameBufferInfo, device.alloc, &frameBuffer).vkCheck;
        }
    }

    ~this()
    {
        if(syncPrimitives)
            destroy(syncPrimitives);

        if(frameBuffer)
            vkDestroyFramebuffer(device, frameBuffer, device.alloc);

        if(imageView)
            vkDestroyImageView(device, imageView, device.alloc);
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
