module pukan.vulkan.renderpass;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;

abstract class RenderPass
{
    VkRenderPass vkRenderPass;
    alias this = vkRenderPass;

    VkFormat imageFormat;
    /// Samples every pipeline of this pass must be created with
    VkSampleCountFlagBits samples = VK_SAMPLE_COUNT_1_BIT;
}

class DefaultRenderPass : RenderPass
{
    LogicalDevice device;
    enum VkFormat depthFormat = DepthBuf.format;
    /// Second pass over the same attachments, loading the colour the first one
    /// left, for draws that sample that colour
    VkRenderPass transmissionPass;
    VariableData data;
    alias this = data;

    this(LogicalDevice dev, VkFormat imageFormat)
    {
        device = dev;
        this.imageFormat = imageFormat;

        samples = VK_SAMPLE_COUNT_4_BIT;

        VkAttachmentDescription colorAttachment = defaultColorAttachment;
        colorAttachment.format = imageFormat;
        colorAttachment.samples = samples;

        VkAttachmentReference colorAttachmentRef = {
            attachment: 0,
            layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        VkAttachmentDescription depthAttachment = defaultDepthAttachment;
        depthAttachment.format = depthFormat;
        depthAttachment.samples = samples;

        VkAttachmentReference depthAttachmentRef = {
            layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            attachment: 1,
        };

        VkAttachmentDescription resolveAttachment = defaultResolveAttachment;
        resolveAttachment.format = imageFormat;

        VkAttachmentReference resolveAttachmentRef = {
            attachment: 2,
            layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        auto attachments = [
            colorAttachment,
            depthAttachment,
            resolveAttachment,
        ];

        VkSubpassDescription[] subpasses = [
            {
                pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
                colorAttachmentCount: 1,
                pColorAttachments: &colorAttachmentRef,
            },
            {
                pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
                colorAttachmentCount: 1,
                pColorAttachments: &colorAttachmentRef,
                pResolveAttachments: &resolveAttachmentRef,
                pDepthStencilAttachment: &depthAttachmentRef,
            },
        ];

        VkSubpassDependency[] dependencies = [
            {
                srcSubpass: VK_SUBPASS_EXTERNAL,
                dstSubpass: 0,
                srcStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                srcAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                dstStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                dstAccessMask: VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            },
            {
                srcSubpass: 0,
                dstSubpass: 1,
                srcStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                srcAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                dstStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                dstAccessMask: VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            },
            {
                srcSubpass: VK_SUBPASS_EXTERNAL,
                dstSubpass: 1,
                srcStageMask: VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
                srcAccessMask: VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                dstStageMask: VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
                dstAccessMask: VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            },
        ];

        VkRenderPassCreateInfo renderPassInfo = {
            attachmentCount: cast(uint) attachments.length,
            pAttachments: attachments.ptr,
            subpassCount: cast(uint) subpasses.length,
            pSubpasses: subpasses.ptr,
            dependencyCount: cast(uint) dependencies.length,
            pDependencies: dependencies.ptr,
        };

        vkCall(device, &renderPassInfo, device.alloc, &vkRenderPass);

        {
            // The colour leaves the first pass as a copy source and comes back
            // for the second, which loads instead of clearing
            VkAttachmentDescription color = colorAttachment;
            color.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
            color.initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

            VkAttachmentDescription depth = depthAttachment;
            depth.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
            depth.initialLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

            VkAttachmentDescription resolve = resolveAttachment;
            resolve.initialLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            resolve.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

            auto secondAttachments = [color, depth, resolve];

            VkSubpassDescription[] secondSubpasses = [
                {
                    pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
                    colorAttachmentCount: 1,
                    pColorAttachments: &colorAttachmentRef,
                },
                {
                    pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
                    colorAttachmentCount: 1,
                    pColorAttachments: &colorAttachmentRef,
                    pResolveAttachments: &resolveAttachmentRef,
                    pDepthStencilAttachment: &depthAttachmentRef,
                },
            ];

            // Render pass compatibility covers the dependencies, so they match
            // the first pass exactly
            VkSubpassDependency[] secondDependencies = dependencies;

            VkRenderPassCreateInfo secondInfo = {
                attachmentCount: cast(uint) secondAttachments.length,
                pAttachments: secondAttachments.ptr,
                subpassCount: cast(uint) secondSubpasses.length,
                pSubpasses: secondSubpasses.ptr,
                dependencyCount: cast(uint) secondDependencies.length,
                pDependencies: secondDependencies.ptr,
            };

            vkCall(device, &secondInfo, device.alloc, &transmissionPass);
        }
    }

    ~this()
    {
        if(vkRenderPass)
            vkDestroyRenderPass(device, vkRenderPass, device.alloc);

        if(transmissionPass)
            vkDestroyRenderPass(device, transmissionPass, device.alloc);
    }

    enum VkAttachmentDescription defaultColorAttachment = {
        samples: VK_SAMPLE_COUNT_1_BIT,
        loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
        storeOp: VK_ATTACHMENT_STORE_OP_STORE,
        stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
        initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
        finalLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    enum VkAttachmentDescription defaultDepthAttachment = {
        samples: VK_SAMPLE_COUNT_1_BIT,
        loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
        storeOp: VK_ATTACHMENT_STORE_OP_STORE,
        stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
        initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
        finalLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    /// Single-sample image the multisampled colour resolves into
    enum VkAttachmentDescription defaultResolveAttachment = {
        samples: VK_SAMPLE_COUNT_1_BIT,
        loadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        storeOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
        stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
        initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
        finalLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    static struct CommonData
    {
        VkExtent2D imageExtent;
        VkFramebuffer frameBuffer;
    }

    static struct VariableData
    {
        CommonData common;
        alias this = common;
    }

    VkViewport viewport;
    VkRect2D scissor;

    void updateData(VariableData d)
    {
        data = d;

        viewport = VkViewport(
            x: 0.0f,
            y: 0.0f,
            width: cast(float) imageExtent.width,
            height: cast(float) imageExtent.height,
            minDepth: 0.0f,
            maxDepth: 1.0f,
        );

        scissor = VkRect2D(
            offset: VkOffset2D(0, 0),
            extent: imageExtent,
        );
    }

    void recordCommandBuffer(
        VkCommandBuffer commandBuffer,
        void delegate(ref VkCommandBuffer) draw2D,
        void delegate(ref VkCommandBuffer) draw3D,
    )
    {
        VkRenderPassBeginInfo renderPassInfo;
        renderPassInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        renderPassInfo.renderPass = vkRenderPass;
        renderPassInfo.framebuffer = frameBuffer;
        renderPassInfo.renderArea.offset = VkOffset2D(0, 0);
        renderPassInfo.renderArea.extent = imageExtent;

        auto clearValues = [
            VkClearValue(
                color: VkClearColorValue(float32: [0.0f, 0.0f, 0.0f, 1.0f]),
            ),
            VkClearValue(
                depthStencil: VkClearDepthStencilValue(1, 0),
            ),
        ];

        renderPassInfo.pClearValues = clearValues.ptr;
        renderPassInfo.clearValueCount = cast(uint) clearValues.length;

        vkCmdBeginRenderPass(commandBuffer, &renderPassInfo, VK_SUBPASS_CONTENTS_INLINE);

        vkCmdSetViewport(commandBuffer, 0, 1, &viewport);

        vkCmdSetScissor(commandBuffer, 0, 1, &scissor);

        draw2D(commandBuffer);

        vkCmdNextSubpass(commandBuffer, VK_SUBPASS_CONTENTS_INLINE);

        draw3D(commandBuffer);

        vkCmdEndRenderPass(commandBuffer);
    }

    /// Second pass over the same framebuffer, drawing what samples the copy
    void recordTransmissionCommandBuffer(
        VkCommandBuffer commandBuffer,
        void delegate(ref VkCommandBuffer) draw,
    )
    {
        VkRenderPassBeginInfo renderPassInfo;
        renderPassInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        renderPassInfo.renderPass = transmissionPass;
        renderPassInfo.framebuffer = frameBuffer;
        renderPassInfo.renderArea.offset = VkOffset2D(0, 0);
        renderPassInfo.renderArea.extent = imageExtent;

        vkCmdBeginRenderPass(commandBuffer, &renderPassInfo, VK_SUBPASS_CONTENTS_INLINE);

        vkCmdNextSubpass(commandBuffer, VK_SUBPASS_CONTENTS_INLINE);

        vkCmdSetViewport(commandBuffer, 0, 1, &viewport);
        vkCmdSetScissor(commandBuffer, 0, 1, &scissor);

        draw(commandBuffer);

        vkCmdEndRenderPass(commandBuffer);
    }
}

/// Which of the two 3D passes a draw belongs to
enum DrawPhase : uint
{
    /// Opaque and blended draws, before the colour copy
    surface,
    /// Draws that sample the copy of the colour the surface phase left
    transmission,
}

///
interface DrawableByVulkan
{
    import dlib.math: Matrix4x4f;

    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer);
    void refreshBuffers(VkCommandBuffer buf);
    void drawingBufferFilling(
        VkCommandBuffer buf,
        Matrix4x4f trans,
        VkDescriptorSet frameSet,
        DrawPhase phase = DrawPhase.surface,
    );
}

/// Drawables that must be ordered back to front implement this
interface Blended
{
    bool isBlended() const;
}
