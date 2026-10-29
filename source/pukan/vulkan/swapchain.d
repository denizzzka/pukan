module pukan.vulkan.swapchain;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.requirements: Requirement;
import std.exception: enforce;
import std.meta: AliasSeq;

/// Surface format pairs the scene can render into, best first
private enum surfaceFormatPreference = [
    VkSurfaceFormatKHR(VK_FORMAT_B8G8R8A8_SRGB, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
    VkSurfaceFormatKHR(VK_FORMAT_R8G8B8A8_SRGB, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
];

/// Picks the surface format the scene can render into, VK_FORMAT_UNDEFINED when none
VkSurfaceFormatKHR chooseSurfaceFormat(VkPhysicalDevice pd, VkSurfaceKHR surface, out string reason)
{
    import std.algorithm: any;

    const formats = getArrayFrom!vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surface);

    foreach(preferred; surfaceFormatPreference)
        if(formats.any!((available) =>
            (available.format == VK_FORMAT_UNDEFINED || available.format == preferred.format) &&
            available.colorSpace == preferred.colorSpace))
            return preferred;

    reason = "surface has no sRGB format";
    return VkSurfaceFormatKHR(VK_FORMAT_UNDEFINED, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR);
}

/// Returns false and a reason when the surface cannot back a swapchain with the given format
bool surfaceUsable(VkPhysicalDevice pd, VkSurfaceKHR surface, VkSurfaceFormatKHR format, out string reason)
{
    import std.algorithm: any, canFind;

    const formats = getArrayFrom!vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surface);

    if(!formats.any!((available) =>
        (available.format == VK_FORMAT_UNDEFINED || available.format == format.format) &&
        available.colorSpace == format.colorSpace))
    {
        reason = "surface does not support the swapchain color format";
        return false;
    }

    const presentModes = getArrayFrom!vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surface);

    if(!presentModes.canFind(VK_PRESENT_MODE_FIFO_KHR))
    {
        reason = "surface does not support FIFO present mode";
        return false;
    }

    return true;
}

class SwapChain
{
    private static alias requirements = AliasSeq!(
        Requirement!(VK_KHR_SWAPCHAIN_EXTENSION_NAME),
    );

    LogicalDevice device;
    VkSwapchainKHR swapchain;
    VkPresentModeKHR presentMode;
    private SwapChain oldSwapChain;
    FrameBuilder frameBuilder;
    VkImage[] images;
    VkFormat imageFormat;
    VkExtent2D imageExtent;
    enum maxFramesInFlight = 3;
    /// Frames a replaced swapchain and its images stay alive
    enum oldSwapchainFrames = 30;
    Frame[] frames;
    int currentFrameIdx;
    VkQueue presentQueue;

    private ubyte framesSinceSwapchainReplacement = 0;

    this(
        LogicalDevice device,
        FrameBuilder fb,
        VkSurfaceKHR surface,
        RenderPass renderPass,
        SwapChain old,
        VkColorSpaceKHR imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        VkPresentModeKHR preferredPresentMode = VK_PRESENT_MODE_FIFO_KHR,
    )
    {
        auto physDev = device.physicalDevice;
        const capab = physDev.instance.getSurfaceCapabilities(physDev.physicalDevice, surface);

        this(device, fb, capab, renderPass, old, imageColorSpace, preferredPresentMode);
    }

    this(
        LogicalDevice device,
        FrameBuilder fb,
        VkSurfaceCapabilitiesKHR capabilities,
        RenderPass renderPass,
        SwapChain old,
        VkColorSpaceKHR imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        VkPresentModeKHR preferredPresentMode = VK_PRESENT_MODE_FIFO_KHR,
    )
    {
        import pukan.exceptions: PukanVulkanException;
        import std.algorithm: canFind;
        import std.conv: to;

        auto cap = capabilities;

        enforce(cap.currentExtent.width != uint.max, "unsupported, see VkSurfaceCapabilitiesKHR(3) Manual Page");
        enforce(cap.minImageCount > 0);
        enforce(cap.maxImageCount == 0 || cap.maxImageCount >= 3, "maxImageCount: "~cap.maxImageCount.to!string);

        auto surface = device.physicalDevice.instance.surface.handle;
        string reason;
        enforce(surfaceUsable(device.physicalDevice.physicalDevice, surface,
                VkSurfaceFormatKHR(renderPass.imageFormat, imageColorSpace), reason),
            new PukanVulkanException(reason));

        const presentModes = getArrayFrom!vkGetPhysicalDeviceSurfacePresentModesKHR(device.physicalDevice.physicalDevice, surface);

        VkPresentModeKHR selectedPresentMode = VK_PRESENT_MODE_FIFO_KHR;
        foreach(candidate; [
            preferredPresentMode,
            VK_PRESENT_MODE_MAILBOX_KHR,
            VK_PRESENT_MODE_IMMEDIATE_KHR,
            VK_PRESENT_MODE_FIFO_KHR,
        ])
            if(presentModes.canFind(candidate))
            {
                selectedPresentMode = candidate;
                break;
            }

        enforce(cap.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
            "swapchain images cannot be copied from");

        VkSwapchainCreateInfoKHR cinf = {
            sType: VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            surface: device.physicalDevice.instance.surface.handle,
            imageFormat: renderPass.imageFormat,
            imageColorSpace: imageColorSpace,
            imageExtent: capabilities.currentExtent,
            imageArrayLayers: 1, // number of views in a multiview/stereo surface. For non-stereoscopic-3D applications, this value is 1
            imageUsage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
            imageSharingMode: VK_SHARING_MODE_EXCLUSIVE,
            presentMode: selectedPresentMode,
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
        presentMode = cinf.presentMode;

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
            frame = new Frame(frameBuilder, images[i], imageExtent, imageFormat, renderPass, renderPass.samples);
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
        // To ensure that all buffers and queues are no longer in use
        if(oldSwapChain !is null)
        {
            if(framesSinceSwapchainReplacement < oldSwapchainFrames)
                framesSinceSwapchainReplacement++;
            else
            {
                destroy(oldSwapChain);
                oldSwapChain = null;
                framesSinceSwapchainReplacement = 0;
            }
        }
    }
}
