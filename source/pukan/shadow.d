module pukan.shadow;

import dlib.math: Matrix4x4f, Vector3f, Vector4f;
import pukan.camera: cameraView, vulkanPerspectiveMatrix;
import pukan.misc: Boxf, vulkanOrthographicMatrix;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.renderpass: RenderPass;

/// Depth-only pass that renders the sun's view of the scene
final class ShadowPass : RenderPass
{
    LogicalDevice device;

    this(LogicalDevice device, VkFormat depthFormat)
    {
        this.device = device;
        this.depthFormat = depthFormat;
        samples = VK_SAMPLE_COUNT_1_BIT;

        VkAttachmentDescription depth = {
            format: depthFormat,
            samples: samples,
            loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
            storeOp: VK_ATTACHMENT_STORE_OP_STORE,
            stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            finalLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        };

        VkAttachmentReference depthRef = {
            attachment: 0,
            layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };

        VkSubpassDescription subpass = {
            pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
            pDepthStencilAttachment: &depthRef,
        };

        VkSubpassDependency dependency = {
            srcSubpass: VK_SUBPASS_EXTERNAL,
            dstSubpass: 0,
            srcStageMask: VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
            srcAccessMask: VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            dstStageMask: VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
            dstAccessMask: VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        };

        VkRenderPassCreateInfo info = {
            attachmentCount: 1,
            pAttachments: &depth,
            subpassCount: 1,
            pSubpasses: &subpass,
            dependencyCount: 1,
            pDependencies: &dependency,
        };

        vkCall(device, &info, device.alloc, &vkRenderPass);
    }

    ~this()
    {
        if(vkRenderPass)
            vkDestroyRenderPass(device, vkRenderPass, device.alloc);
    }

    void record(
        VkCommandBuffer buf,
        VkFramebuffer frameBuffer,
        VkExtent2D extent,
        void delegate(ref VkCommandBuffer) draw,
    )
    {
        VkRenderPassBeginInfo info = {
            sType: VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            renderPass: vkRenderPass,
            framebuffer: frameBuffer,
            renderArea: VkRect2D(
                offset: VkOffset2D(0, 0),
                extent: extent,
            ),
        };

        VkClearValue clear = {
            depthStencil: VkClearDepthStencilValue(1.0f, 0),
        };
        info.pClearValues = &clear;
        info.clearValueCount = 1;

        VkViewport viewport = {
            x: 0.0f,
            y: 0.0f,
            width: cast(float) extent.width,
            height: cast(float) extent.height,
            minDepth: 0.0f,
            maxDepth: 1.0f,
        };
        VkRect2D scissor = {
            offset: VkOffset2D(0, 0),
            extent: extent,
        };

        vkCmdBeginRenderPass(buf, &info, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdSetViewport(buf, 0, 1, &viewport);
        vkCmdSetScissor(buf, 0, 1, &scissor);

        draw(buf);

        vkCmdEndRenderPass(buf);
    }
}

/// Depth image and framebuffer the shadow pass renders into, one per frame
final class ShadowMap
{
    private LogicalDevice device;
    private ImageMemory depth;
    private VkImageView view;
    private VkFramebuffer frameBuffer;
    private VkExtent2D extent;

    this(LogicalDevice device, ShadowPass pass, uint size)
    {
        this.device = device;
        extent = VkExtent2D(size, size);

        VkImageCreateInfo imageInfo = {
            sType: VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            imageType: VK_IMAGE_TYPE_2D,
            format: pass.depthFormat,
            tiling: VK_IMAGE_TILING_OPTIMAL,
            extent: VkExtent3D(size, size, 1),
            mipLevels: 1,
            arrayLayers: 1,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usage: VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
            samples: VK_SAMPLE_COUNT_1_BIT,
        };

        depth = device.create!ImageMemory(imageInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        VkImageViewCreateInfo viewInfo = {
            sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            viewType: VK_IMAGE_VIEW_TYPE_2D,
            format: pass.depthFormat,
            subresourceRange: VkImageSubresourceRange(
                aspectMask: VK_IMAGE_ASPECT_DEPTH_BIT,
                baseMipLevel: 0,
                levelCount: 1,
                baseArrayLayer: 0,
                layerCount: 1,
            ),
            image: depth.image,
        };
        vkCreateImageView(device, &viewInfo, device.alloc, &view).vkCheck;

        VkFramebufferCreateInfo frameBufferInfo = {
            sType: VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            renderPass: pass.vkRenderPass,
            attachmentCount: 1,
            pAttachments: &view,
            width: size,
            height: size,
            layers: 1,
        };
        vkCreateFramebuffer(device, &frameBufferInfo, device.alloc, &frameBuffer).vkCheck;

        // Valid sampled layout even while the pass is off and nothing writes it
        {
            auto pool = device.createCommandPool();
            auto bufs = pool.allocateBuffers(1);

            pool.recordOneTimeAndSubmit(bufs[0], (VkCommandBuffer buf) {
                VkImageMemoryBarrier barrier = {
                    sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                    oldLayout: VK_IMAGE_LAYOUT_UNDEFINED,
                    newLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                    srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
                    dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
                    image: depth.image,
                    srcAccessMask: 0,
                    dstAccessMask: VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                    subresourceRange: VkImageSubresourceRange(
                        aspectMask: VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT,
                        baseMipLevel: 0,
                        levelCount: 1,
                        baseArrayLayer: 0,
                        layerCount: 1,
                    ),
                };

                vkCmdPipelineBarrier(buf, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                    VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT, 0, 0, null, 0, null, 1, &barrier);

                barrier.oldLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
                barrier.newLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL;
                barrier.srcAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
                barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;

                vkCmdPipelineBarrier(buf, VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
                    VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
            });

            pool.freeBuffers(bufs);
            destroy(pool);
        }
    }

    ~this()
    {
        if(frameBuffer)
            vkDestroyFramebuffer(device, frameBuffer, device.alloc);

        if(view)
            vkDestroyImageView(device, view, device.alloc);

        if(depth)
            destroy(depth);
    }

    VkFramebuffer renderedFrameBuffer() => frameBuffer;
    VkExtent2D renderExtent() const => extent;

    VkDescriptorImageInfo imageInfo(VkSampler sampler)
    {
        return VkDescriptorImageInfo(
            imageLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
            imageView: view,
            sampler: sampler,
        );
    }
}

/// The sun's shadow map: one depth image per frame in flight
final class SunShadow
{
    private LogicalDevice device;
    ShadowPass pass;
    private ShadowMap[] maps;
    private bool[] valid;
    private VkSampler sampler;

    /// Renders the map again only after `invalidate`
    bool cache;
    bool enabled = true;
    /// Side of the square map
    uint mapSize = 1024;
    /// Light view-projection the pass and the PBR shaders share
    Matrix4x4f viewProj = Matrix4x4f.identity;
    /// NDC depth bias that keeps the world-space offset constant
    float depthBias = 0.0015f;

    private Boxf bounds;
    private bool hasBounds;
    private enum fallbackFov = 24.0f;
    private enum fallbackDistance = 10.0f;

    this(LogicalDevice device, uint mapSize = 1024)
    in(mapSize > 0)
    {
        this.device = device;
        this.mapSize = mapSize;
        pass = new ShadowPass(device, DepthBuf.format);

        VkSamplerCreateInfo info = {
            sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            magFilter: VK_FILTER_LINEAR,
            minFilter: VK_FILTER_LINEAR,
            mipmapMode: VK_SAMPLER_MIPMAP_MODE_NEAREST,
            addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            compareEnable: VK_TRUE,
            compareOp: VK_COMPARE_OP_LESS_OR_EQUAL,
            borderColor: VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE,
            unnormalizedCoordinates: VK_FALSE,
        };
        vkCall(device.device, &info, device.alloc, &sampler);
    }

    ~this()
    {
        foreach(ref map; maps)
            if(map)
                destroy(map);

        if(sampler)
            vkDestroySampler(device.device, sampler, device.alloc);

        if(pass)
            destroy(pass);
    }

    /// Fits the map around `bounds`; a box without bounds restores the fallback
    void fit(in Boxf bounds)
    {
        import std.math: isNaN;

        this.bounds = bounds;
        hasBounds = !bounds.min.x.isNaN;
        invalidate();
    }

    void invalidate()
    {
        valid[] = false;
    }

    void recreate(size_t frameCount)
    {
        if(maps.length == frameCount)
            return;

        foreach(ref map; maps)
            if(map)
                destroy(map);

        maps.length = frameCount;
        valid.length = frameCount;
        valid[] = false;

        foreach(i; 0 .. frameCount)
            maps[i] = new ShadowMap(device, pass, mapSize);
    }

    /// Rebuilds the light matrix; `sunDirection` points toward the sun
    void update(Vector3f sunDirection)
    {
        const sun = sunDirection.normalized;

        if(!hasBounds)
        {
            const eye = sun * fallbackDistance;
            const view = cameraView(eye, Vector3f(0, 0, 0), Vector3f(0, 1, 0));
            const proj = vulkanPerspectiveMatrix(fallbackFov, 1.0f, 1.0f, fallbackDistance * 2.0f);
            viewProj = proj * view;
            depthBias = 0.0015f;
            return;
        }

        const center = (bounds.min + bounds.max) * 0.5f;
        const extent = (bounds.max - bounds.min) * 0.5f;
        const radius = extent.length;
        const eye = center + sun * (radius * 2.0f + 1.0f);
        const view = cameraView(eye, center, Vector3f(0, 1, 0));

        float xMin = float.max;
        float xMax = -float.max;
        float yMin = float.max;
        float yMax = -float.max;
        float zMin = float.max;
        float zMax = -float.max;

        foreach(i; 0 .. 8)
        {
            const corner = Vector3f(
                (i & 1) ? bounds.max.x : bounds.min.x,
                (i & 2) ? bounds.max.y : bounds.min.y,
                (i & 4) ? bounds.max.z : bounds.min.z,
            );
            const p = Vector4f(corner.x, corner.y, corner.z, 1) * view;

            if(p.x < xMin) xMin = p.x;
            if(p.x > xMax) xMax = p.x;
            if(p.y < yMin) yMin = p.y;
            if(p.y > yMax) yMax = p.y;
            if(p.z < zMin) zMin = p.z;
            if(p.z > zMax) zMax = p.z;
        }

        auto padding = radius * 0.02f;
        if(padding < 0.5f)
            padding = 0.5f;

        auto nearPlane = -zMax - padding;
        if(nearPlane < 0.01f)
            nearPlane = 0.01f;
        const farPlane = -zMin + padding;

        viewProj = vulkanOrthographicMatrix(
            xMin - padding, xMax + padding,
            yMin - padding, yMax + padding,
            nearPlane, farPlane,
        ) * view;

        // A fixed depth offset in world units: the orthographic range is large
        depthBias = 0.03f / (farPlane - nearPlane);
    }

    VkDescriptorImageInfo imageInfo(size_t frameIndex)
    {
        assert(frameIndex < maps.length);
        return maps[frameIndex].imageInfo(sampler);
    }

    /// Returns false when the cached map is reused
    bool record(size_t frameIndex, VkCommandBuffer buf, void delegate(ref VkCommandBuffer) draw)
    {
        assert(frameIndex < maps.length);

        if(!enabled || draw is null)
            return false;

        if(cache && valid[frameIndex])
            return false;

        pass.record(buf, maps[frameIndex].renderedFrameBuffer, maps[frameIndex].renderExtent, draw);
        valid[frameIndex] = true;

        return true;
    }
}
