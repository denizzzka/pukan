module pukan.oit;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.pipelines: FixedState, GraphicsPipelineCfg, PipelineFactory, RenderTechnique;
import pukan.vulkan.renderpass: RenderPass;

/// Fragments the per-frame buffer holds; must match OIT_MAX_FRAGMENTS in oit.glsl
enum oitMaxFragments = 524288;
/// The GLSL std430 stride of OitFragment
private enum oitFragmentBytes = 4 * uint.sizeof;

/// Single colour attachment the resolved lists blend into
final class OitResolvePass : RenderPass
{
    private LogicalDevice device;

    this(LogicalDevice device, VkFormat imageFormat)
    {
        this.device = device;
        this.imageFormat = imageFormat;
        samples = VK_SAMPLE_COUNT_1_BIT;

        VkAttachmentDescription color = {
            format: imageFormat,
            samples: samples,
            loadOp: VK_ATTACHMENT_LOAD_OP_LOAD,
            storeOp: VK_ATTACHMENT_STORE_OP_STORE,
            stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
            initialLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            finalLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        VkAttachmentReference colorRef = {
            attachment: 0,
            layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        VkSubpassDescription subpass = {
            pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
            colorAttachmentCount: 1,
            pColorAttachments: &colorRef,
        };

        VkSubpassDependency dependency = {
            srcSubpass: VK_SUBPASS_EXTERNAL,
            dstSubpass: 0,
            srcStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            srcAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            dstStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            dstAccessMask: VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        };

        VkRenderPassCreateInfo info = {
            attachmentCount: 1,
            pAttachments: &color,
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
}

/// Draws the sorted fragment lists of one frame over its colour
final class OitResolve
{
    OitResolvePass pass;
    GraphicsPipelineCfg pipeline;

    this(LogicalDevice device, PipelineFactory pipelines, VkFormat imageFormat)
    {
        pass = new OitResolvePass(device, imageFormat);

        auto stages = [
            device.uploadShaderToGPU(
                cast(ubyte[]) import("fullscreen_vert.spv"),
                VK_SHADER_STAGE_VERTEX_BIT,
                [],
            ),
            device.uploadShaderToGPU(
                cast(ubyte[]) import("oit_resolve_frag.spv"),
                VK_SHADER_STAGE_FRAGMENT_BIT,
                [],
                VkPushConstantRange(
                    stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
                    offset: 0,
                    size: uint.sizeof,
                ),
            ),
        ];

        auto technique = pipelines.declare(RenderTechnique(
            name: "OIT resolve",
            stages: stages,
            state: FixedState(
                cullMode: VK_CULL_MODE_NONE,
                depthTestEnable: VK_FALSE,
                depthWriteEnable: VK_FALSE,
                blendEnable: VK_TRUE,
            ),
        ));

        pipeline = pipelines.acquire(technique, pass, 0);
    }

    ~this()
    {
        if(pass)
            destroy(pass);
    }
}

/// Writes the nearest multisampled depth per pixel, for the blended resolve
final class DepthResolvePass : RenderPass
{
    private LogicalDevice device;

    this(LogicalDevice device, VkFormat imageFormat)
    {
        this.device = device;
        this.imageFormat = imageFormat;
        samples = VK_SAMPLE_COUNT_1_BIT;

        VkAttachmentDescription color = {
            format: imageFormat,
            samples: samples,
            loadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            storeOp: VK_ATTACHMENT_STORE_OP_STORE,
            stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            finalLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        VkAttachmentReference colorRef = {
            attachment: 0,
            layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        VkSubpassDescription subpass = {
            pipelineBindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS,
            colorAttachmentCount: 1,
            pColorAttachments: &colorRef,
        };

        VkSubpassDependency dependency = {
            srcSubpass: VK_SUBPASS_EXTERNAL,
            dstSubpass: 0,
            srcStageMask: VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            srcAccessMask: VK_ACCESS_SHADER_READ_BIT,
            dstStageMask: VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            dstAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        };

        VkRenderPassCreateInfo info = {
            attachmentCount: 1,
            pAttachments: &color,
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

    void record(VkCommandBuffer buf, VkFramebuffer frameBuffer, VkExtent2D extent, void delegate(ref VkCommandBuffer) draw)
    {
        VkRenderPassBeginInfo info = {
            sType: VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            renderPass: vkRenderPass,
            framebuffer: frameBuffer,
            renderArea: VkRect2D(offset: VkOffset2D(0, 0), extent: extent),
        };

        VkViewport viewport = {
            x: 0.0f,
            y: 0.0f,
            width: cast(float) extent.width,
            height: cast(float) extent.height,
            minDepth: 0.0f,
            maxDepth: 1.0f,
        };
        VkRect2D scissor = { offset: VkOffset2D(0, 0), extent: extent };

        vkCmdBeginRenderPass(buf, &info, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdSetViewport(buf, 0, 1, &viewport);
        vkCmdSetScissor(buf, 0, 1, &scissor);

        draw(buf);

        vkCmdEndRenderPass(buf);
    }
}

/// Full-screen pipeline that turns the MSAA depth into one value per pixel
final class DepthResolve
{
    DepthResolvePass pass;
    GraphicsPipelineCfg pipeline;

    this(LogicalDevice device, PipelineFactory pipelines)
    {
        pass = new DepthResolvePass(device, VK_FORMAT_R32_SFLOAT);

        auto stages = [
            device.uploadShaderToGPU(
                cast(ubyte[]) import("fullscreen_vert.spv"),
                VK_SHADER_STAGE_VERTEX_BIT,
                [],
            ),
            device.uploadShaderToGPU(
                cast(ubyte[]) import("depth_resolve_frag.spv"),
                VK_SHADER_STAGE_FRAGMENT_BIT,
                [],
            ),
        ];

        auto technique = pipelines.declare(RenderTechnique(
            name: "depth resolve",
            stages: stages,
            state: FixedState(
                cullMode: VK_CULL_MODE_NONE,
                depthTestEnable: VK_FALSE,
                depthWriteEnable: VK_FALSE,
            ),
        ));

        pipeline = pipelines.acquire(technique, pass, 0);
    }

    ~this()
    {
        if(pass)
            destroy(pass);
    }
}

/// Fragment lists and the framebuffer the resolve pass draws into, one per frame
final class OitFrame
{
    private LogicalDevice device;
    private ImageMemory heads;
    private VkImageView headsView;
    private MemoryBuffer fragments;
    private MemoryBuffer counter;
    private VkFramebuffer frameBuffer;
    private ImageMemory sceneDepth;
    private VkImageView sceneDepthView;
    private VkFramebuffer sceneDepthFrameBuffer;

    this(
        LogicalDevice device,
        OitResolvePass pass,
        DepthResolvePass depthPass,
        VkImageView colorView,
        VkExtent2D extent,
    )
    {
        this.device = device;

        VkImageCreateInfo headsInfo = {
            sType: VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            imageType: VK_IMAGE_TYPE_2D,
            format: VK_FORMAT_R32_UINT,
            tiling: VK_IMAGE_TILING_OPTIMAL,
            extent: VkExtent3D(extent.width, extent.height, 1),
            mipLevels: 1,
            arrayLayers: 1,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usage: VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
            samples: VK_SAMPLE_COUNT_1_BIT,
        };

        heads = device.create!ImageMemory(headsInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        createImageView(headsView, device, VK_FORMAT_R32_UINT, heads.image);

        VkBufferCreateInfo fragmentsInfo = {
            sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            size: oitMaxFragments * oitFragmentBytes,
            usage: VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
        };
        fragments = device.create!MemoryBuffer(fragmentsInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        VkBufferCreateInfo counterInfo = {
            sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            size: uint.sizeof,
            usage: VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
        };
        counter = device.create!MemoryBuffer(counterInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        VkFramebufferCreateInfo frameBufferInfo = {
            sType: VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            renderPass: pass.vkRenderPass,
            attachmentCount: 1,
            pAttachments: &colorView,
            width: extent.width,
            height: extent.height,
            layers: 1,
        };
        vkCreateFramebuffer(device, &frameBufferInfo, device.alloc, &frameBuffer).vkCheck;

        // Nearest depth the blended resolve compares against
        {
            VkImageCreateInfo depthInfo = {
                sType: VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                imageType: VK_IMAGE_TYPE_2D,
                format: VK_FORMAT_R32_SFLOAT,
                tiling: VK_IMAGE_TILING_OPTIMAL,
                extent: VkExtent3D(extent.width, extent.height, 1),
                mipLevels: 1,
                arrayLayers: 1,
                initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
                usage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                sharingMode: VK_SHARING_MODE_EXCLUSIVE,
                samples: VK_SAMPLE_COUNT_1_BIT,
            };

            sceneDepth = device.create!ImageMemory(depthInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
            createImageView(sceneDepthView, device, VK_FORMAT_R32_SFLOAT, sceneDepth.image);

            VkFramebufferCreateInfo depthFrameBufferInfo = {
                sType: VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                renderPass: depthPass.vkRenderPass,
                attachmentCount: 1,
                pAttachments: &sceneDepthView,
                width: extent.width,
                height: extent.height,
                layers: 1,
            };
            vkCreateFramebuffer(device, &depthFrameBufferInfo, device.alloc, &sceneDepthFrameBuffer).vkCheck;
        }

        {
            auto pool = device.createCommandPool();
            auto bufs = pool.allocateBuffers(1);

            pool.recordOneTimeAndSubmit(bufs[0], (VkCommandBuffer buf) {
                VkImageMemoryBarrier barrier = {
                    sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                    oldLayout: VK_IMAGE_LAYOUT_UNDEFINED,
                    newLayout: VK_IMAGE_LAYOUT_GENERAL,
                    srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
                    dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
                    image: heads.image,
                    srcAccessMask: 0,
                    dstAccessMask: VK_ACCESS_TRANSFER_WRITE_BIT,
                    subresourceRange: VkImageSubresourceRange(
                        aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
                        baseMipLevel: 0,
                        levelCount: 1,
                        baseArrayLayer: 0,
                        layerCount: 1),
                };

                vkCmdPipelineBarrier(buf, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                    0, 0, null, 0, null, 1, &barrier);

                recordClearCommands(buf, heads.image, counter.buf);
            });

            pool.freeBuffers(bufs);
            destroy(pool);
        }

        // Valid sampled layout before the first depth resolve writes it
        {
            auto pool = device.createCommandPool();
            auto bufs = pool.allocateBuffers(1);

            pool.recordOneTimeAndSubmit(bufs[0], (VkCommandBuffer buf) {
                VkImageMemoryBarrier barrier = {
                    sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                    oldLayout: VK_IMAGE_LAYOUT_UNDEFINED,
                    newLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
                    dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
                    image: sceneDepth.image,
                    srcAccessMask: 0,
                    dstAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                    subresourceRange: VkImageSubresourceRange(
                        aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
                        baseMipLevel: 0,
                        levelCount: 1,
                        baseArrayLayer: 0,
                        layerCount: 1,
                    ),
                };

                vkCmdPipelineBarrier(buf, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                    VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, &barrier);

                barrier.oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
                barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                barrier.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
                barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;

                vkCmdPipelineBarrier(buf, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                    VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
            });

            pool.freeBuffers(bufs);
            destroy(pool);
        }
    }

    ~this()
    {
        if(sceneDepthFrameBuffer)
            vkDestroyFramebuffer(device, sceneDepthFrameBuffer, device.alloc);

        if(sceneDepthView)
            vkDestroyImageView(device, sceneDepthView, device.alloc);

        if(sceneDepth)
            destroy(sceneDepth);

        if(frameBuffer)
            vkDestroyFramebuffer(device, frameBuffer, device.alloc);

        if(headsView)
            vkDestroyImageView(device, headsView, device.alloc);

        if(heads)
            destroy(heads);

        if(fragments)
            destroy(fragments);

        if(counter)
            destroy(counter);
    }

    VkDescriptorImageInfo headsImageInfo()
    {
        return VkDescriptorImageInfo(
            imageLayout: VK_IMAGE_LAYOUT_GENERAL,
            imageView: headsView,
        );
    }

    VkDescriptorBufferInfo fragmentsInfo()
    {
        return VkDescriptorBufferInfo(
            buffer: fragments.buf,
            offset: 0,
            range: oitMaxFragments * oitFragmentBytes,
        );
    }

    VkDescriptorBufferInfo counterInfo()
    {
        return VkDescriptorBufferInfo(
            buffer: counter.buf,
            offset: 0,
            range: uint.sizeof,
        );
    }

    VkFramebuffer renderedFrameBuffer() => frameBuffer;

    VkFramebuffer renderedSceneDepthFrameBuffer() => sceneDepthFrameBuffer;

    VkDescriptorImageInfo sceneDepthInfo()
    {
        return VkDescriptorImageInfo(
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            imageView: sceneDepthView,
        );
    }

    /// Empties the lists before the frame records its fragments
    void recordClear(VkCommandBuffer buf)
    {
        VkImageMemoryBarrier barrier = {
            sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            oldLayout: VK_IMAGE_LAYOUT_GENERAL,
            newLayout: VK_IMAGE_LAYOUT_GENERAL,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            image: heads.image,
            srcAccessMask: VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
            dstAccessMask: VK_ACCESS_TRANSFER_WRITE_BIT,
            subresourceRange: VkImageSubresourceRange(
                aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
                baseMipLevel: 0,
                levelCount: 1,
                baseArrayLayer: 0,
                layerCount: 1),
        };

        vkCmdPipelineBarrier(buf, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, null, 0, null, 1, &barrier);

        VkBufferMemoryBarrier counterBarrier = {
            sType: VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            buffer: counter.buf,
            offset: 0,
            size: VK_WHOLE_SIZE,
            srcAccessMask: VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
            dstAccessMask: VK_ACCESS_TRANSFER_WRITE_BIT,
        };

        vkCmdPipelineBarrier(buf, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, null, 1, &counterBarrier, 0, null);

        recordClearCommands(buf, heads.image, counter.buf);

        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;

        vkCmdPipelineBarrier(buf, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0, 0, null, 0, null, 1, &barrier);

        counterBarrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        counterBarrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;

        vkCmdPipelineBarrier(buf, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0, 0, null, 1, &counterBarrier, 0, null);
    }

    private static void recordClearCommands(VkCommandBuffer buf, VkImage image, VkBuffer counter)
    {
        VkClearColorValue clear = {
            uint32: [0xFFFFFFFFu, 0u, 0u, 0u],
        };

        VkImageSubresourceRange range = {
            aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
            baseMipLevel: 0,
            levelCount: 1,
            baseArrayLayer: 0,
            layerCount: 1,
        };

        vkCmdClearColorImage(buf, image, VK_IMAGE_LAYOUT_GENERAL, &clear, 1, &range);

        vkCmdFillBuffer(buf, counter, 0, uint.sizeof, 0);
    }
}
