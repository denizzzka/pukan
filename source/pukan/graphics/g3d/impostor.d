module pukan.graphics.g3d.impostor;

import pukan.graphics.g3d.stats: countDraw;
import dlib.math: Matrix4x4f, Vector3f, cross, dot;
import pukan.graphics.common.misc: Boxf, hasBounds, mergeAabb, vulkanOrthographicMatrix;
import pukan.graphics.common.shaders: shaderStage;
import pukan.graphics.g3d.camera: cameraView;
import pukan.vulkan.bindings;
import pukan.vulkan.descriptors: imageWriteDescriptor;
import pukan.vulkan.frame_builder: DepthBuf, createImageView;
import pukan.vulkan.helpers: vkCheck;
import pukan.vulkan.image: ImageMemory;
import pukan.vulkan.resources.vkobj: VkObj;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.pipelines: DescriptorAllocator, FixedState, GraphicsPipelineCfg, PipelineFactory, RenderTechnique;
import pukan.vulkan.renderpass: DefaultRenderPass;
import std.math: abs;

/**
    Colour the far ring showed for one cell.

    A cell is rendered once into its own small image, from the direction of the
    camera that loaded it, and drawn later as a card instead of its parts.
*/
struct CellImpostor
{
    /// Centre and radius of the sphere the card covers
    Vector3f center;
    float radius;
    private size_t slot;
    /// Set once the image holds the cell; a cleared cell draws nothing
    bool captured;
}

/// Owns the capture targets, the billboard pipeline and their images
final class Impostors
{
    private static struct Quad
    {
        Vector3f center;
        Vector3f right;
        Vector3f up;
        float radius;
    }

    private final class Slot
    {
        LogicalDevice device;
        ImageMemory resolve;
        VkObj!VkImageView resolveView;
        VkObj!VkFramebuffer frameBuffer;
        VkDescriptorSet set;
        Quad quad;

        ~this()
        {
            if(device is null)
                return;

            if(resolve)
                destroy(resolve);
        }
    }

    private LogicalDevice device;
    private PipelineFactory pipelines;
    private DefaultRenderPass pass;
    private VkFormat colorFormat;
    private uint size;
    private GraphicsPipelineCfg billboard;
    private DescriptorAllocator allocator;
    private VkSampler sampler;
    private Slot[] slots;
    /// One multisampled colour and depth serve every capture, one at a time
    private ImageMemory msaa;
    private VkObj!VkImageView msaaView;
    private DepthBuf depth;

    this(
        LogicalDevice device,
        PipelineFactory pipelines,
        DefaultRenderPass pass,
        VkFormat colorFormat,
        uint size = 128,
    )
    in(size > 0)
    {
        this.device = device;
        this.pipelines = pipelines;
        this.pass = pass;
        this.colorFormat = colorFormat;
        this.size = size;

        auto technique = pipelines.declare(RenderTechnique(
            name: "impostor",
            stages: [
                shaderStage!"impostor_vert.spv"(
                    VK_SHADER_STAGE_VERTEX_BIT,
                    null,
                    VkPushConstantRange(
                        stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                        offset: 0,
                        size: Matrix4x4f.sizeof,
                    ),
                ),
                shaderStage!"impostor_frag.spv"(
                    VK_SHADER_STAGE_FRAGMENT_BIT,
                    [
                        VkDescriptorSetLayoutBinding(
                            binding: 0,
                            descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                            descriptorCount: 1,
                            stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
                        ),
                    ],
                ),
            ],
            state: FixedState(
                topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
                cullMode: VK_CULL_MODE_NONE,
                depthTestEnable: VK_TRUE,
                depthWriteEnable: VK_TRUE,
            ),
        ), 1);

        billboard = pipelines.acquire(technique, pass, 1);

        allocator = pipelines.descriptorAllocator(technique);

        VkSamplerCreateInfo samplerInfo = {
            sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            magFilter: VK_FILTER_LINEAR,
            minFilter: VK_FILTER_LINEAR,
            mipmapMode: VK_SAMPLER_MIPMAP_MODE_NEAREST,
            addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        };
        vkCreateSampler(device, &samplerInfo, device.alloc, &sampler).vkCheck;

        VkImageCreateInfo msaaInfo = imageInfo(colorFormat, pass.samples);
        msaa = device.create!ImageMemory(msaaInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        msaaView = createImageView(device, colorFormat, msaa.image);

        depth = DepthBuf(device, VkExtent2D(size, size), pass.depthFormat, pass.samples);
    }

    ~this()
    {
        foreach(slot; slots)
            if(slot)
                destroy(slot);

        if(msaa)
            destroy(msaa);

        if(sampler)
            vkDestroySampler(device, sampler, device.alloc);
    }

    /**
        Renders the cell into a new image.

        `bounds` are the parts the cell holds, `eye` is where the viewer stood
        when the cell arrived, and `draw` records the cell with the given matrix.
    */
    CellImpostor capture(
        VkCommandBuffer buf,
        scope const(Boxf)[] bounds,
        in Vector3f eye,
        scope void delegate(VkCommandBuffer buf, in Matrix4x4f viewProj) draw,
    )
    {
        Boxf box;

        foreach(part; bounds)
        {
            if(!hasBounds(part))
                continue;

            if(hasBounds(box))
                mergeAabb(box, part);
            else
                box = part;
        }

        if(!hasBounds(box))
            return CellImpostor.init;

        const center = (box.min + box.max) * 0.5f;
        const radius = (box.max - box.min).length * 0.5f;

        if(!(radius > 0))
            return CellImpostor.init;

        auto direction = center - eye;

        if(direction.length < 1e-4f)
            direction = Vector3f(0, 0, 1);
        else
            direction = direction.normalized;

        Vector3f up = Vector3f(0, 1, 0);

        if(abs(dot(direction, up)) > 0.99f)
            up = Vector3f(1, 0, 0);

        const right = cross(direction, up).normalized;
        up = cross(right, direction).normalized;

        const slotIndex = slots.length;
        slots ~= new Slot;
        ref slot = slots[slotIndex];

        createSlot(slot, center, right, up, radius);

        // The view stands on the viewer's side, so the cell shows its front faces
        const distant = radius * 2.0f;
        const viewProj = vulkanOrthographicMatrix(-radius, radius, -radius, radius, radius * 0.5f, radius * 4.0f)
            * cameraView(center - direction * distant, center, up);

        recordCapture(buf, slot, viewProj, draw);

        return CellImpostor(center, radius, slotIndex, true);
    }

    /// Draws the card of a captured cell, facing the side it was captured from
    void draw(VkCommandBuffer buf, in CellImpostor impostor, in Matrix4x4f viewProj)
    {
        if(!impostor.captured)
            return;

        ref slot = slots[impostor.slot];

        // Columns are the card's axes, so a local corner lands on the plane
        Matrix4x4f quad = Matrix4x4f.identity;
        quad.a11 = slot.quad.right.x;
        quad.a21 = slot.quad.right.y;
        quad.a31 = slot.quad.right.z;
        quad.a12 = slot.quad.up.x;
        quad.a22 = slot.quad.up.y;
        quad.a32 = slot.quad.up.z;
        quad.a14 = slot.quad.center.x;
        quad.a24 = slot.quad.center.y;
        quad.a34 = slot.quad.center.z;

        const mvp = viewProj * quad;

        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, billboard.graphicsPipeline);
        vkCmdPushConstants(buf, billboard.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, mvp.sizeof, &mvp);

        vkCmdBindDescriptorSets(
            buf,
            VK_PIPELINE_BIND_POINT_GRAPHICS,
            billboard.pipelineLayout,
            0,
            1,
            &slot.set,
            0,
            null,
        );

        vkCmdDraw(buf, 4, 1, 0, 0);

        // The card is one quad, two triangles
        countDraw(1, 2);
    }

    private void createSlot(ref Slot slot, in Vector3f center, in Vector3f right, in Vector3f up, float radius)
    {
        slot.device = device;

        VkImageCreateInfo resolveInfo = imageInfo(colorFormat, VK_SAMPLE_COUNT_1_BIT);
        resolveInfo.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
        slot.resolve = device.create!ImageMemory(resolveInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        slot.resolveView = createImageView(device, colorFormat, slot.resolve.image);

        VkImageView[] attachments = [msaaView.vk, depth.depthView, slot.resolveView.vk];

        VkFramebufferCreateInfo frameBufferInfo = {
            renderPass: pass.vkRenderPass,
            attachmentCount: cast(uint) attachments.length,
            pAttachments: attachments.ptr,
            width: size,
            height: size,
            layers: 1,
        };
        slot.frameBuffer = VkObj!VkFramebuffer(device.releaseQueue, frameBufferInfo);

        VkDescriptorImageInfo imageInfo = {
            sampler: sampler,
            imageView: slot.resolveView.vk,
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        slot.set = allocator.allocate();

        VkWriteDescriptorSet[] writes = [
            imageWriteDescriptor(slot.set, 0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, imageInfo),
        ];
        device.updateDescriptorSets(writes);

        slot.quad = Quad(center, right, up, radius);
    }

    private VkImageCreateInfo imageInfo(VkFormat format, VkSampleCountFlagBits samples)
    {
        return VkImageCreateInfo(
            sType: VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            imageType: VK_IMAGE_TYPE_2D,
            format: format,
            tiling: VK_IMAGE_TILING_OPTIMAL,
            extent: VkExtent3D(size, size, 1),
            mipLevels: 1,
            arrayLayers: 1,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
            samples: samples,
        );
    }

    private void transitionToRead(VkCommandBuffer buf, VkImage image)
    {
        VkImageMemoryBarrier barrier = {
            sType: VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            oldLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            newLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            image: image,
            srcAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            dstAccessMask: VK_ACCESS_SHADER_READ_BIT,
            subresourceRange: VkImageSubresourceRange(
                aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
                baseMipLevel: 0,
                levelCount: 1,
                baseArrayLayer: 0,
                layerCount: 1,
            ),
        };

        vkCmdPipelineBarrier(buf, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
    }

    private void recordCapture(
        VkCommandBuffer buf,
        ref Slot slot,
        in Matrix4x4f viewProj,
        scope void delegate(VkCommandBuffer buf, in Matrix4x4f viewProj) draw,
    )
    {
        VkRenderPassBeginInfo info = {
            sType: VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            renderPass: pass.vkRenderPass,
            framebuffer: slot.frameBuffer.vk,
            renderArea: VkRect2D(offset: VkOffset2D(0, 0), extent: VkExtent2D(size, size)),
        };

        auto clears = [
            VkClearValue(color: VkClearColorValue(float32: [0.0f, 0.0f, 0.0f, 0.0f])),
            VkClearValue(depthStencil: VkClearDepthStencilValue(0.0f, 0)),
        ];
        info.pClearValues = clears.ptr;
        info.clearValueCount = cast(uint) clears.length;

        VkViewport viewport = {
            x: 0.0f,
            y: 0.0f,
            width: cast(float) size,
            height: cast(float) size,
            minDepth: 0.0f,
            maxDepth: 1.0f,
        };
        VkRect2D scissor = {
            offset: VkOffset2D(0, 0),
            extent: VkExtent2D(size, size),
        };

        vkCmdBeginRenderPass(buf, &info, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdNextSubpass(buf, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdSetViewport(buf, 0, 1, &viewport);
        vkCmdSetScissor(buf, 0, 1, &scissor);

        draw(buf, viewProj);

        vkCmdEndRenderPass(buf);

        transitionToRead(buf, slot.resolve.image);
    }
}
