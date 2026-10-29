module pukan.shadow;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.renderpass: RenderPass;

/// Depth-only pass that renders the sun's view of the scene
final class ShadowPass : RenderPass
{
    LogicalDevice device;
    VkFormat depthFormat;

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
