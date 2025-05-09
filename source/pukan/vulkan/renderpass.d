module pukan.vulkan.renderpass;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.helpers;

abstract class RenderPass
{
    VkRenderPass vkRenderPass;
    alias this = vkRenderPass;

    VkFormat imageFormat;
    void recordCommandBuffer(VkCommandBuffer commandBuffer);
}

class DefaultRenderPass : RenderPass
{
    LogicalDevice device;
    enum VkFormat depthFormat = DepthBuf.format;
    VariableData data;
    alias this = data;

    this(LogicalDevice dev, VkFormat imageFormat)
    {
        device = dev;
        this.imageFormat = imageFormat;

        VkAttachmentDescription colorAttachment = defaultColorAttachment;
        colorAttachment.format = imageFormat;

        VkAttachmentReference colorAttachmentRef = {
            attachment: 0,
            layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        VkAttachmentDescription depthAttachment = defaultDepthAttachment;
        depthAttachment.format = depthFormat;

        VkAttachmentReference depthAttachmentRef = {
            layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            attachment: 1,
        };

        auto attachments = [
            colorAttachment,
            depthAttachment,
        ];

        VkSubpassDescription subpass = {
            pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
            colorAttachmentCount: 1,
            pColorAttachments: &colorAttachmentRef,
            pDepthStencilAttachment: &depthAttachmentRef,
        };

        VkSubpassDependency dependency = defaultSubpassDependency;

        VkRenderPassCreateInfo renderPassInfo = {
            attachmentCount: cast(uint) attachments.length,
            pAttachments: attachments.ptr,
            subpassCount: 1,
            pSubpasses: &subpass,
            dependencyCount: 1,
            pDependencies: &dependency,
        };

        vkCall(device, &renderPassInfo, device.backend.allocator, &vkRenderPass);
    }

    ~this()
    {
        if(vkRenderPass)
            vkDestroyRenderPass(device, vkRenderPass, device.backend.allocator);
    }

    enum VkAttachmentDescription defaultColorAttachment = {
        samples: VK_SAMPLE_COUNT_1_BIT,
        loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
        storeOp: VK_ATTACHMENT_STORE_OP_STORE,
        stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
        initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
        finalLayout: VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    enum VkAttachmentDescription defaultDepthAttachment = {
        samples: VK_SAMPLE_COUNT_1_BIT,
        loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
        storeOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
        stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
        initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
        finalLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    enum VkSubpassDependency defaultSubpassDependency = {
        srcSubpass: VK_SUBPASS_EXTERNAL,
        dstSubpass: 0,
        srcStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        srcAccessMask: 0,
        dstStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        dstAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    };

    static struct VariableData
    {
        VkExtent2D imageExtent;
        VkFramebuffer frameBuffer;
        VkBuffer vertexBuffer;
        VkBuffer indexBuffer;
        VkDescriptorSet[] descriptorSets;
        VkPipelineLayout pipelineLayout;
        VkPipeline graphicsPipeline;
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

    void drawIndexed(VkCommandBuffer buf)
    {
        auto vertexBuffers = [vertexBuffer];
        VkDeviceSize[] offsets = [VkDeviceSize(0)];

        vkCmdBindVertexBuffers(buf, 0, 1, vertexBuffers.ptr, offsets.ptr);
        vkCmdBindIndexBuffer(buf, indexBuffer, 0, VK_INDEX_TYPE_UINT16);
        vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, cast(uint) descriptorSets.length, descriptorSets.ptr, 0, null);

        vkCmdDrawIndexed(buf, cast(uint) indices.length, 1, 0, 0, 0);
    }

    override void recordCommandBuffer(VkCommandBuffer commandBuffer)
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

        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, graphicsPipeline);

        vkCmdSetViewport(commandBuffer, 0, 1, &viewport);

        vkCmdSetScissor(commandBuffer, 0, 1, &scissor);

        drawIndexed(commandBuffer);

        vkCmdEndRenderPass(commandBuffer);
    }
}
