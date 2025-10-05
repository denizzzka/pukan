module pukan.vulkan.swapchain;

import pukan.vulkan;
import pukan.vulkan.bindings;
import std.exception: enforce;

class SwapChain
{
    LogicalDevice device;
    VkSwapchainKHR swapchain;
    SwapChain oldSwapChain;
    FrameBuilder frameBuilder;
    VkImage[] images;
    VkFormat imageFormat;
    VkExtent2D imageExtent;
    enum maxFramesInFlight = 3;
    Frame[] frames;
    int currentFrameIdx;
    VkQueue presentQueue;

    private ubyte framesSinceSwapchainReplacement = 0;

    this(LogicalDevice device, FrameBuilder fb, VkSurfaceKHR surface, RenderPass renderPass, SwapChain old)
    {
        auto ins = device.physicalDevice.instance;

        auto physDev = ins.findSuitablePhysicalDevice;
        const capab = ins.getSurfaceCapabilities(physDev.physicalDevice, surface);

        this(device, fb, capab, renderPass, old);
    }

    this(LogicalDevice device, FrameBuilder fb, VkSurfaceCapabilitiesKHR capabilities, RenderPass renderPass, SwapChain old)
    {
        import std.conv: to;

        auto cap = capabilities;

        enforce(cap.currentExtent.width != uint.max, "unsupported, see VkSurfaceCapabilitiesKHR(3) Manual Page");
        enforce(cap.minImageCount > 0);
        enforce(cap.maxImageCount == 0 || cap.maxImageCount >= 3, "maxImageCount: "~cap.maxImageCount.to!string);

        VkSwapchainCreateInfoKHR cinf = {
            sType: VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            surface: device.physicalDevice.instance.surface,
            imageFormat: renderPass.imageFormat,
            imageColorSpace: VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
            imageExtent: capabilities.currentExtent,
            imageArrayLayers: 1, // number of views in a multiview/stereo surface. For non-stereoscopic-3D applications, this value is 1
            imageUsage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, // specifies that the image can be used to create a VkImageView suitable for use as a color or resolve attachment in a VkFramebuffer
            imageSharingMode: VK_SHARING_MODE_EXCLUSIVE,
            presentMode: VkPresentModeKHR.VK_PRESENT_MODE_FIFO_KHR,
            minImageCount: 3, // triple buffering will be used
            preTransform: capabilities.currentTransform,
            compositeAlpha: VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            clipped: VK_TRUE,
            oldSwapchain: (old is null) ? null : old.swapchain,
        };

        this(device, fb, cinf, renderPass, old);
    }

    this(LogicalDevice d, FrameBuilder fb, VkSwapchainCreateInfoKHR cinf, RenderPass renderPass, SwapChain old)
    {
        device = d;
        frameBuilder = fb;
        oldSwapChain = old;
        presentQueue = device.getQueue();
        imageFormat = cinf.imageFormat;
        imageExtent = cinf.imageExtent;

        debug
        {
            if(old is null)
                assert(cinf.oldSwapchain is null);
            else
                assert(old.swapchain == cinf.oldSwapchain);
        }

        vkCreateSwapchainKHR(d.device, &cinf, d.alloc, &swapchain).vkCheck;
        //TODO: need scope(failure) guard for swapchain?

        images = getArrayFrom!(vkGetSwapchainImagesKHR, maxFramesInFlight)(device.device, swapchain);
        assert(images.length == maxFramesInFlight);

        frames.length = images.length;

        foreach(i, ref frame; frames)
            frame = new Frame(frameBuilder, images[i], imageExtent, imageFormat, renderPass);
    }

    ~this()
    {
        foreach(ref frame; frames)
            destroy(frame);

        destroy(oldSwapChain);

        if(swapchain)
            vkDestroySwapchainKHR(device.device, swapchain, device.alloc);
    }

    private auto ref currSync()
    {
        return currFrame.syncPrimitives;
    }

    private auto ref currFrame()
    {
        return frames[currentFrameIdx];
    }

    void toNextFrame()
    {
        currentFrameIdx = (currentFrameIdx + 1) % maxFramesInFlight;
    }

    /// imageIndex result is "random" index value, not related to currentFrameIdx
    VkResult acquireNextImage(out uint imageIndex)
    {
        return vkAcquireNextImageKHR(device, swapchain, ulong.max /* timeout */, currSync.imageAvailable, null /* fence */, &imageIndex);
    }

    /// Starts displaying frame on the screen
    VkResult queueImageForPresentation(Frame frame, ref uint imageIndex)
    {
        auto sync = frame.syncPrimitives;

        VkSwapchainKHR[1] swapChains = [swapchain];

        VkPresentInfoKHR presentInfo = {
            sType: VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,

            pImageIndices: &imageIndex,

            waitSemaphoreCount: cast(uint) sync.renderFinishedSemaphores.length,
            pWaitSemaphores: sync.renderFinishedSemaphores.ptr,

            swapchainCount: cast(uint) swapChains.length,
            pSwapchains: swapChains.ptr,
        };

        return vkQueuePresentKHR(presentQueue, &presentInfo);
    }

    void oldSwapchainsMaintenance()
    {
        enum framesToOldSwapchainsDestory = 30;

        if(oldSwapChain !is null)
        {
            if(framesSinceSwapchainReplacement < framesToOldSwapchainsDestory)
                framesSinceSwapchainReplacement++;
            else
            {
                destroy(oldSwapChain);
                oldSwapChain = null;
                framesSinceSwapchainReplacement = 0;
            }
        }
    }

    void recToCurrOneTimeBuffer(void delegate(VkCommandBuffer) dg)
    {
        frameBuilder.commandPool.recordOneTime(currFrame.commandBuffer, dg);
    }
}
