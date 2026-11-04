module pukan.graphics.g3d.occlusion_depth;

import pukan.graphics.common.shaders: shaderStage;
import pukan.vulkan.bindings;
import pukan.vulkan.descriptors: bufferWriteDescriptor, imageWriteDescriptor;
import pukan.vulkan.helpers: vkCheck;
import pukan.vulkan.image: transitionImageLayout;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: MemoryBufferMappedToCPU;
import pukan.vulkan.pipelines: PipelineFactory, PipelineKey;
import pukan.vulkan.resources.vkobj: VkObj;

/**
    Reads a frame's multisampled depth into a coarse grid of nearest depths.

    A multisampled depth cannot be copied: `vkCmdCopyImageToBuffer` wants one
    sample and `vkCmdResolveImage` takes colour only. A compute pass samples it
    instead, one nearest depth per grid cell, and the CPU reads that buffer a
    frame later.
*/
final class OcclusionDepth
{
    private LogicalDevice device;
    private PipelineFactory pipelines;
    private PipelineKey key;
    private VkPipelineLayout layout;
    private VkDescriptorSetLayout setLayout;
    private VkPipeline pipeline;
    private VkObj!VkDescriptorPool pool;
    private VkSampler sampler;
    private MemoryBufferMappedToCPU buffer;

    /// Cells per row and column of the grid
    int columns;
    int rows;
    /// Extent the last grid was read at; zero until the first frame
    VkExtent2D extent;
    /// Whether a grid has been written and can be read
    private bool filled;

    private static struct Push
    {
        uint gridWidth;
        uint gridHeight;
        uint texWidth;
        uint texHeight;
        uint samples;
    }

    /// Sets by depth view, because the frames in flight each own one
    private VkDescriptorSet[VkImageView] sets;

    this(LogicalDevice device, PipelineFactory pipelines, int columns, int rows)
    in(columns > 0 && rows > 0)
    {
        this.device = device;
        this.pipelines = pipelines;
        this.columns = columns;
        this.rows = rows;

        VkDescriptorSetLayoutBinding binding(uint index, VkDescriptorType type)
        {
            return VkDescriptorSetLayoutBinding(
                binding: index,
                descriptorType: type,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
            );
        }

        auto bindings = [
            binding(0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER),
            binding(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER),
        ];

        auto declared = pipelines.declareCompute(shaderStage!"occlusion_depth.spv"(
            VK_SHADER_STAGE_COMPUTE_BIT,
            bindings,
            VkPushConstantRange(
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
                offset: 0,
                size: Push.sizeof,
            ),
        ));

        key = declared.key;
        layout = declared.pipelineLayout;
        setLayout = declared.setLayout;
        pool = VkObj!VkDescriptorPool(device.createDescriptorPool(bindings, 8), device.releaseQueue);

        VkSamplerCreateInfo samplerInfo = {
            sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            magFilter: VK_FILTER_NEAREST,
            minFilter: VK_FILTER_NEAREST,
            mipmapMode: VK_SAMPLER_MIPMAP_MODE_NEAREST,
            addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            borderColor: VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            compareEnable: VK_FALSE,
            compareOp: VK_COMPARE_OP_ALWAYS,
        };
        vkCreateSampler(device.device, &samplerInfo, device.alloc, &sampler).vkCheck;

        buffer = device.create!MemoryBufferMappedToCPU(
            cast(size_t) columns * rows * float.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );
    }

    ~this()
    {
        if(buffer)
            destroy(buffer);

        if(sampler)
            vkDestroySampler(device, sampler, device.alloc);
    }

    /// Records the downsample of the depth image; the view feeds the sampler
    void record(
        VkCommandBuffer buf,
        VkImage depthImage,
        VkImageView depth,
        VkExtent2D size,
        uint samples,
    )
    {
        if(size.width == 0 || size.height == 0)
            return;

        if(columns > size.width || rows > size.height)
            return;

        if(pipeline is null)
        {
            auto cfg = pipelines.acquireCompute(key);
            pipeline = cfg.pipeline;
            layout = cfg.pipelineLayout;
        }

        auto found = depth in sets;

        if(found is null)
        {
            auto created = device.allocateDescriptorSet(pool.vk, setLayout);

            VkDescriptorBufferInfo info = VkDescriptorBufferInfo(buffer.buf, 0, VK_WHOLE_SIZE);
            VkDescriptorImageInfo image = VkDescriptorImageInfo(
                imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                imageView: depth,
                sampler: sampler,
            );

            scope VkWriteDescriptorSet[] writes = [
                imageWriteDescriptor(created, 0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, image),
                bufferWriteDescriptor(created, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, info),
            ];

            device.updateDescriptorSets(writes);

            sets[depth] = created;
            found = depth in sets;
        }

        VkDescriptorSet set = *found;

        VkPipelineStageFlags afterDepthWrites =
            VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
        VkPipelineStageFlags computeStage = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
        VkAccessFlags depthWrite = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        VkAccessFlags shaderRead = VK_ACCESS_SHADER_READ_BIT;
        VkAccessFlags depthReadWrite =
            VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        VkImageAspectFlags depthAndStencil =
            VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT;

        transitionImageLayout(
            buf, depthImage,
            VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            afterDepthWrites,
            depthWrite,
            computeStage,
            shaderRead,
            0u, 1u,
            depthAndStencil,
        );

        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
        vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, null);

        const push = Push(
            gridWidth: cast(uint) columns,
            gridHeight: cast(uint) rows,
            texWidth: size.width,
            texHeight: size.height,
            samples: samples,
        );
        vkCmdPushConstants(buf, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, push.sizeof, &push);

        const group = 8;
        vkCmdDispatch(buf, (columns + group - 1) / group, (rows + group - 1) / group, 1);

        VkBufferMemoryBarrier[1] written = [
            VkBufferMemoryBarrier(
                sType: VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
                srcAccessMask: VK_ACCESS_SHADER_WRITE_BIT,
                dstAccessMask: VK_ACCESS_HOST_READ_BIT,
                srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
                dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
                buffer: buffer.buf,
                offset: 0,
                size: VK_WHOLE_SIZE,
            ),
        ];

        vkCmdPipelineBarrier(buf,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
            0, 0, null, cast(uint) written.length, written.ptr, 0, null);

        transitionImageLayout(
            buf, depthImage,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            computeStage,
            shaderRead,
            afterDepthWrites,
            depthReadWrite,
            0u, 1u,
            depthAndStencil,
        );

        extent = size;
        filled = true;
    }

    /// Copies the last grid into `cells`; false when no frame has written one
    bool read(float[] cells) const
    {
        if(!filled || cells.length < columns * rows)
            return false;

        const values = cast(const(float)[]) buffer.cpuBuf;
        cells[0 .. columns * rows] = values[0 .. columns * rows];

        return true;
    }
}
