module pukan.graphics.g3d.shadow;

import dlib.math: Matrix4x4f, Vector3f, Vector4f;
import pukan.graphics.common.misc: Boxf, vulkanOrthographicMatrix;
import pukan.graphics.g3d.camera: cameraView;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers: vkCall, vkCheck;
import pukan.vulkan.image: ImageMemory;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.resources.vkobj: VkObj;
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
            depthStencil: VkClearDepthStencilValue(0.0f, 0),
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

    /// Records one depth pass into a grid of equal tiles, clearing the atlas once
    void recordTiles(
        VkCommandBuffer buf,
        VkFramebuffer frameBuffer,
        VkExtent2D extent,
        uint tileSize,
        size_t tiles,
        void delegate(ref VkCommandBuffer, size_t tile) draw,
    )
    in(tiles > 0 && tileSize > 0)
    in(extent.width % tileSize == 0 && extent.height % tileSize == 0)
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
            depthStencil: VkClearDepthStencilValue(0.0f, 0),
        };
        info.pClearValues = &clear;
        info.clearValueCount = 1;

        vkCmdBeginRenderPass(buf, &info, VK_SUBPASS_CONTENTS_INLINE);

        const columns = extent.width / tileSize;

        foreach(tile; 0 .. tiles)
        {
            const column = cast(uint) tile % columns;
            const row = cast(uint) tile / columns;

            VkViewport viewport = {
                x: cast(float) (column * tileSize),
                y: cast(float) (row * tileSize),
                width: cast(float) tileSize,
                height: cast(float) tileSize,
                minDepth: 0.0f,
                maxDepth: 1.0f,
            };
            VkRect2D scissor = {
                offset: VkOffset2D(column * tileSize, row * tileSize),
                extent: VkExtent2D(tileSize, tileSize),
            };

            vkCmdSetViewport(buf, 0, 1, &viewport);
            vkCmdSetScissor(buf, 0, 1, &scissor);

            draw(buf, tile);
        }

        vkCmdEndRenderPass(buf);
    }
}

/// Depth image and framebuffer the shadow pass renders into, one per frame
final class ShadowMap
{
    private LogicalDevice device;
    private ImageMemory depth;
    private VkObj!VkImageView viewObj;
    private VkObj!VkFramebuffer frameBufferObj;

    @property ref VkImageView view() => viewObj.vk;
    @property ref VkFramebuffer frameBuffer() => frameBufferObj.vk;
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
        viewObj = VkObj!VkImageView(device.releaseQueue, viewInfo);
        auto view = viewObj.vk;

        VkFramebufferCreateInfo frameBufferInfo = {
            renderPass: pass.vkRenderPass,
            attachmentCount: 1,
            pAttachments: &view,
            width: size,
            height: size,
            layers: 1,
        };
        frameBufferObj = VkObj!VkFramebuffer(device.releaseQueue, frameBufferInfo);

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
                        aspectMask: VK_IMAGE_ASPECT_DEPTH_BIT,
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

/// Cascades the sun's shadow splits the camera frustum into
enum sunCascadeCount = 3;

/// The camera frustum split into cascades, each fitted to the sun
struct SunCascades
{
    /// Light view-projection per cascade, nearest first
    Matrix4x4f[sunCascadeCount] viewProj;
    /// NDC depth bias of each cascade, keeping the world-space offset constant
    float[sunCascadeCount] depthBias;
    /// View depth each cascade reaches to
    float[sunCascadeCount] splitFar;
    /// Side of each square map
    uint mapSize;

    /// Share of a cascade's range that fades into the next one
    enum float blendBand = 0.1f;
    /// Share the logarithmic split takes over the uniform one
    private enum float splitLambda = 0.65f;
    /// World-space depth offset the NDC bias stands for
    private enum float biasWorld = 0.03f;

    private Matrix4x4f[sunCascadeCount] lastViewProj;
    private Boxf bounds;
    private bool hasBounds;

    this(uint mapSize)
    in(mapSize > 0)
    {
        this.mapSize = mapSize;

        foreach(ref matrix; viewProj)
            matrix = Matrix4x4f.identity;

        foreach(ref matrix; lastViewProj)
            matrix = Matrix4x4f.identity;

        depthBias[] = 0.0015f;
        splitFar[] = float.max;
    }

    /// Depth this cascade fades into the next one over
    float blend(int cascade) const
    {
        return (splitFar[cascade] - (cascade == 0 ? 0.0f : splitFar[cascade - 1])) * blendBand;
    }

    /// Bounds the level covers; the last cascade need not reach past it
    void fit(in Boxf bounds)
    {
        import std.math: isNaN;

        this.bounds = bounds;
        hasBounds = !bounds.min.x.isNaN;
    }

    /// Rebuilds the cascades; returns true when the fit moved
    bool update(Vector3f sunDirection, in Vector3f eye, in Matrix4x4f invViewProj)
    {
        import std.algorithm: max, min;
        import std.math: abs, floor, pow;

        const sun = sunDirection.normalized;
        const up = abs(sun.y) > 0.99f ? Vector3f(0, 0, 1) : Vector3f(0, 1, 0);

        Vector3f[8] corners;

        foreach(i; 0 .. 8)
        {
            const ndc = Vector3f(
                (i & 1) ? 1.0f : -1.0f,
                (i & 2) ? 1.0f : -1.0f,
                (i & 4) ? 0.0f : 1.0f,
            );
            const p = Vector4f(ndc.x, ndc.y, ndc.z, 1) * invViewProj;
            corners[i] = Vector3f(p.x, p.y, p.z) / p.w;
        }

        const nearCenter = (corners[0] + corners[1] + corners[2] + corners[3]) * 0.25f;
        const farCenter = (corners[4] + corners[5] + corners[6] + corners[7]) * 0.25f;
        const near = max((nearCenter - eye).length, 0.01f);
        const cameraFar = max((farCenter - eye).length, near * 1.01f);
        float far = cameraFar;

        // Cascades stop where the level does
        if(hasBounds)
        {
            float reach = near;

            foreach(i; 0 .. 8)
            {
                const corner = Vector3f(
                    (i & 1) ? bounds.max.x : bounds.min.x,
                    (i & 2) ? bounds.max.y : bounds.min.y,
                    (i & 4) ? bounds.max.z : bounds.min.z,
                );
                reach = max(reach, (corner - eye).length);
            }

            far = min(far, reach);
        }

        far = max(far, near * 1.01f);

        foreach(c; 0 .. sunCascadeCount)
        {
            const t = cast(float) (c + 1) / sunCascadeCount;
            const logarithmic = near * pow(far / near, t);
            const uniform = near + (far - near) * t;

            splitFar[c] = splitLambda * logarithmic + (1 - splitLambda) * uniform;
        }

        foreach(c; 0 .. sunCascadeCount)
        {
            // The next cascade starts a band earlier, so both cover the fade
            const start = c == 0 ? near : max(splitFar[c - 1] - blend(c - 1), near);
            const t0 = (start - near) / (cameraFar - near);
            const t1 = (splitFar[c] - near) / (cameraFar - near);

            Vector3f[8] slice;

            foreach(j; 0 .. 4)
            {
                const a = corners[j];
                const b = corners[j + 4];

                slice[j] = a + (b - a) * t0;
                slice[j + 4] = a + (b - a) * t1;
            }

            Vector3f center = Vector3f(0, 0, 0);

            foreach(corner; slice)
                center += corner;

            center *= 0.125f;

            float radius = 1.0f;

            foreach(corner; slice)
                radius = max(radius, (corner - center).length);

            // The light sits behind the slice, so all of it stays in front
            const view = cameraView(center + sun * (radius * 2.0f + 1.0f), center, up);

            float zMin = float.max;

            foreach(corner; slice)
                zMin = min(zMin, (Vector4f(corner.x, corner.y, corner.z, 1) * view).z);

            const padding = radius * 0.02f + 0.5f;
            const farPlane = -zMin + padding;

            // Reaching back to the light keeps casters above the slice in the map
            const nearPlane = 0.01f;

            // The box is anchored to a world grid of whole texels, so the map
            // slides a texel at a time instead of swimming under the camera
            Matrix4x4f rotation = view;
            rotation.a14 = 0;
            rotation.a24 = 0;
            rotation.a34 = 0;

            const texel = 2.0f * radius / mapSize;
            const worldCenter = Vector4f(center.x, center.y, center.z, 1) * rotation;
            const x = floor(worldCenter.x / texel + 0.5f) * texel - worldCenter.x;
            const y = floor(worldCenter.y / texel + 0.5f) * texel - worldCenter.y;

            viewProj[c] = vulkanOrthographicMatrix(
                x - radius, x + radius,
                y - radius, y + radius,
                nearPlane, farPlane,
            ) * view;

            depthBias[c] = biasWorld / (farPlane - nearPlane);
        }

        bool moved;

        foreach(c; 0 .. sunCascadeCount)
            if(!(viewProj[c] == lastViewProj[c]))
                moved = true;

        if(moved)
            lastViewProj = viewProj;

        return moved;
    }
}

unittest
{
    import pukan.graphics.g3d.camera: cameraView, vulkanPerspectiveMatrix;

    const eye = Vector3f(3, 4, 5);
    const view = cameraView(eye, Vector3f(3, 4, -20), Vector3f(0, 1, 0));
    const invViewProj = (vulkanPerspectiveMatrix(60.0f, 4.0f / 3.0f, 0.1f, 200.0f) * view).inverse;
    const sun = Vector3f(0.3f, 1, 0.2f).normalized;

    SunCascades cascades = SunCascades(1024);
    cascades.update(sun, eye, invViewProj);

    foreach(c; 1 .. sunCascadeCount)
        assert(cascades.splitFar[c] > cascades.splitFar[c - 1], "each cascade reaches farther");

    // The plane each cascade reaches to has to land inside its own map
    const forward = Vector3f(0, 0, -1);

    foreach(c; 0 .. sunCascadeCount)
    {
        const point = eye + forward * cascades.splitFar[c];
        const clip = Vector4f(point.x, point.y, point.z, 1) * cascades.viewProj[c];
        const ndc = Vector3f(clip.x, clip.y, clip.z) / clip.w;

        assert(clip.w > 0);
        assert(ndc.x >= -1 && ndc.x <= 1);
        assert(ndc.y >= -1 && ndc.y <= 1);
        assert(ndc.z >= 0 && ndc.z <= 1);
    }

    // The fade band has to sit inside both maps it mixes
    foreach(c; 1 .. sunCascadeCount)
    {
        const previous = cascades.splitFar[c - 1] - cascades.blend(c - 1) * 0.5f;
        const point = eye + forward * previous;

        foreach(k; [c - 1, c])
        {
            const clip = Vector4f(point.x, point.y, point.z, 1) * cascades.viewProj[k];
            const ndc = Vector3f(clip.x, clip.y, clip.z) / clip.w;

            assert(ndc.x >= -1 && ndc.x <= 1);
            assert(ndc.y >= -1 && ndc.y <= 1);
            assert(ndc.z >= 0 && ndc.z <= 1);
        }
    }

    // The same camera gives the same fit, so the map does not swim
    SunCascades again = SunCascades(1024);
    again.update(sun, eye, invViewProj);

    assert(again.viewProj == cascades.viewProj);
}

/// The sun's shadow maps: one depth image per cascade per frame in flight
final class SunShadow
{
    private LogicalDevice device;
    ShadowPass pass;
    private ShadowMap[] maps;
    private bool[] valid;
    private VkSampler sampler;

    /// Renders a map again only after `invalidate`
    bool cache;
    bool enabled = true;
    /// Side of each square map
    uint mapSize = 1024;
    /// Cascades the maps and the shaders share
    SunCascades cascades;

    this(LogicalDevice device, uint mapSize = 1024)
    in(mapSize > 0)
    {
        this.device = device;
        this.mapSize = mapSize;
        cascades = SunCascades(mapSize);
        pass = new ShadowPass(device, VK_FORMAT_D32_SFLOAT);

        VkSamplerCreateInfo info = {
            sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            magFilter: VK_FILTER_LINEAR,
            minFilter: VK_FILTER_LINEAR,
            mipmapMode: VK_SAMPLER_MIPMAP_MODE_NEAREST,
            addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            compareEnable: VK_TRUE,
            compareOp: VK_COMPARE_OP_GREATER_OR_EQUAL,
            borderColor: VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK,
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

    /// Bounds the level covers; the last cascade need not reach past it
    void fit(in Boxf bounds)
    {
        cascades.fit(bounds);
        invalidate();
    }

    void invalidate()
    {
        valid[] = false;
    }

    void recreate(size_t frameCount)
    {
        if(maps.length == frameCount * sunCascadeCount)
            return;

        foreach(ref map; maps)
            if(map)
                destroy(map);

        maps.length = frameCount * sunCascadeCount;
        valid.length = maps.length;
        valid[] = false;

        foreach(i; 0 .. maps.length)
            maps[i] = new ShadowMap(device, pass, mapSize);
    }

    /// Rebuilds the cascades; `sunDirection` points toward the sun
    void update(Vector3f sunDirection, in Vector3f eye, in Matrix4x4f invViewProj)
    {
        if(cascades.update(sunDirection, eye, invViewProj))
            invalidate();
    }

    VkDescriptorImageInfo imageInfo(size_t frameIndex, size_t cascade)
    {
        const slot = frameIndex * sunCascadeCount + cascade;
        assert(slot < maps.length);
        return maps[slot].imageInfo(sampler);
    }

    /// Whether `record` still draws this cascade in the frame
    bool pending(size_t frameIndex, size_t cascade) const
    {
        return enabled && !(cache && valid[frameIndex * sunCascadeCount + cascade]);
    }

    /// Returns false when every cascade reused its cached map
    bool record(size_t frameIndex, VkCommandBuffer buf, void delegate(ref VkCommandBuffer, size_t cascade) draw)
    {
        assert(frameIndex * sunCascadeCount < maps.length);

        if(!enabled || draw is null)
            return false;

        bool recorded;

        foreach(cascade; 0 .. sunCascadeCount)
            if(recordCascade(frameIndex, cascade, buf, draw))
                recorded = true;

        return recorded;
    }

    private bool recordCascade(size_t frameIndex, size_t cascade, VkCommandBuffer buf,
        void delegate(ref VkCommandBuffer, size_t) draw)
    {
        const slot = frameIndex * sunCascadeCount + cascade;

        if(cache && valid[slot])
            return false;

        pass.record(buf, maps[slot].renderedFrameBuffer, maps[slot].renderExtent,
            (ref VkCommandBuffer b) { draw(b, cascade); });
        valid[slot] = true;

        return true;
    }
}

/// Side of one local light's tile in the shadow atlas
enum localTileSize = 256;
/// Tiles per axis; a spot takes one, a point light six
enum localTilesPerAxis = 4;
/// Tiles the local lights share
enum localShadowCount = localTilesPerAxis * localTilesPerAxis;

/// The local lights' shadow atlas: one depth image per frame in flight
final class LocalShadow
{
    private LogicalDevice device;
    ShadowPass pass;
    private ShadowMap[] maps;
    private bool[] valid;
    private VkSampler sampler;

    /// Renders the atlas again only after `invalidate`
    bool cache;
    bool enabled = true;
    /// Tiles the scene assigned in this frame
    uint active;
    /// Light view-projection of each tile
    Matrix4x4f[localShadowCount] viewProj;
    /// NDC depth bias of each tile
    float[localShadowCount] depthBias;

    this(LogicalDevice device)
    {
        this.device = device;
        pass = new ShadowPass(device, VK_FORMAT_D32_SFLOAT);

        foreach(ref matrix; viewProj)
            matrix = Matrix4x4f.identity;

        depthBias[] = 0.0025f;

        VkSamplerCreateInfo info = {
            sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            magFilter: VK_FILTER_LINEAR,
            minFilter: VK_FILTER_LINEAR,
            mipmapMode: VK_SAMPLER_MIPMAP_MODE_NEAREST,
            addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            compareEnable: VK_TRUE,
            compareOp: VK_COMPARE_OP_GREATER_OR_EQUAL,
            borderColor: VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK,
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
        valid.length = frameCount * localShadowCount;
        valid[] = false;

        foreach(i; 0 .. frameCount)
            maps[i] = new ShadowMap(device, pass, localTilesPerAxis * localTileSize);
    }

    VkDescriptorImageInfo imageInfo(size_t frameIndex)
    {
        assert(frameIndex < maps.length);
        return maps[frameIndex].imageInfo(sampler);
    }

    /// Whether `record` has a tile to draw in this frame
    bool pending(size_t frameIndex) const
    {
        if(!enabled || active == 0)
            return false;

        foreach(tile; 0 .. active)
            if(!(cache && valid[frameIndex * localShadowCount + tile]))
                return true;

        return false;
    }

    /// Returns false when the atlas reused its cached tiles
    bool record(size_t frameIndex, VkCommandBuffer buf, void delegate(ref VkCommandBuffer, size_t tile) draw)
    {
        assert(frameIndex * localShadowCount < valid.length || active == 0);

        if(!enabled || draw is null || active == 0)
            return false;

        if(cache && !pending(frameIndex))
            return false;

        pass.recordTiles(buf, maps[frameIndex].renderedFrameBuffer, maps[frameIndex].renderExtent,
            localTileSize, active, draw);

        foreach(tile; 0 .. active)
            valid[frameIndex * localShadowCount + tile] = true;

        return true;
    }
}
