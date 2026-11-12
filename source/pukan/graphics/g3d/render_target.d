module pukan.graphics.g3d.render_target;

import pukan.graphics.common.frame_pacer: FramePacer;
import pukan.graphics.common.screenshot: Screenshot;
import pukan.graphics.g3d.oit: OitFrame;
import pukan.graphics.g3d.pbr.culling: CullFrame;
import pukan.graphics.g3d.pbr.instancing: InstanceArena;
import pukan.vulkan.bindings;
import pukan.vulkan.frame_builder: FrameBuilder;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: MemoryBufferMappedToCPU;
import pukan.vulkan.renderpass: RenderPass;
import pukan.vulkan.resources.ownership: ResourceOwner;
import pukan.vulkan.resources.vkobj: VkObj;
import pukan.vulkan.swapchain: SwapChain;

/// One target of a scene: a window surface or owned images, its frames, its
/// pacing and the per-frame resources every view needs.
final class RenderTarget
{
    LogicalDevice device;
    string name;
    VkSurfaceFormatKHR format;
    SwapChain swapChain;
    VkPresentModeKHR presentMode;
    /// Owns the window surface; null for an offscreen target
    VkObj!VkSurfaceKHR surface;
    FramePacer pacer;
    /// Called when the surface reports a new size
    void delegate() windowSizeChanged;
    /// Skips acquire and present while a window has no drawable size
    bool paused;

    /// Per-frame resources of this target; released before its frames do
    ResourceOwner!false owner;
    ResourceOwner!false oitOwner;
    InstanceArena[] instanceArenas;
    CullFrame[] cullFrames;
    MemoryBufferMappedToCPU[] lightBufs;
    OitFrame[] oitFrames;

    /// First frame slot this target takes in the scene's shadow maps
    size_t slotBase;

    /// Frame capture this target still has to write
    Screenshot pendingScreenshot;
    string pendingScreenshotPath;
    /// Path of the frame this target saved last
    string lastScreenshotPath;

    this(
        LogicalDevice device,
        FrameBuilder frameBuilder,
        RenderPass renderPass,
        VkSurfaceKHR windowSurface,
        string name,
        VkSurfaceFormatKHR format,
        VkPresentModeKHR presentMode,
        void delegate() windowSizeChanged,
    )
    {
        this.device = device;
        this.name = name;
        this.format = format;
        this.presentMode = presentMode;
        this.windowSizeChanged = windowSizeChanged;

        auto instance = device.physicalDevice.instance;
        surface = VkObj!VkSurfaceKHR(windowSurface, instance.instance.vk, instance.allocator);

        swapChain = new SwapChain(
            device,
            frameBuilder,
            windowSurface,
            renderPass,
            null,
            format.colorSpace,
            presentMode,
        );
    }

    /// Renders into owned images; nothing is presented
    this(
        LogicalDevice device,
        FrameBuilder frameBuilder,
        RenderPass renderPass,
        VkExtent2D extent,
        string name,
        VkFormat format,
    )
    in(extent.width > 0 && extent.height > 0)
    {
        this.device = device;
        this.name = name;
        this.format = VkSurfaceFormatKHR(format, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR);
        presentMode = VK_PRESENT_MODE_FIFO_KHR;

        swapChain = new SwapChain(device, frameBuilder, extent, format, renderPass);
    }

    ~this()
    {
        if(pendingScreenshot)
            destroy(pendingScreenshot);

        if(owner)
            destroy(owner);

        if(swapChain)
            destroy(swapChain);
    }

    VkExtent2D extent() const => swapChain.imageExtent;

    size_t frameCount() const => swapChain.frames.length;

    /// Index of one of this target's frames in the scene's shadow maps
    size_t frameSlot(size_t frameIndex) const => slotBase + frameIndex;

    bool offscreen() const => swapChain.isOffscreen();

    VkSurfaceKHR surfaceHandle() => surface.vk;
}
