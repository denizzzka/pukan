module pukan.graphics.g3d.occlusion_depth;

import pukan.graphics.common.shaders: shaderStage;
import pukan.vulkan.bindings;
import pukan.vulkan.descriptors: bufferWriteDescriptor, imageWriteDescriptor;
import pukan.vulkan.helpers: vkCheck;
import pukan.vulkan.image: ImageMemory, transitionImageLayout, depthStencilAspect;
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

    One grid serves one view: stereo keeps a grid per eye, each built from its
    own rectangle of the depth image and sampled in that view's normalized
    coordinates.
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

    /// One view's coarse grid and its readback buffer
    private static struct Grid
    {
        MemoryBufferMappedToCPU buffer;
        ImageMemory image;
        VkObj!VkImageView viewObj;
        /// Sets by depth view, because the frames in flight each own one
        VkDescriptorSet[VkImageView] sets;
        bool filled;
    }

    private Grid[] grids;

    /// Cells per row and column of each grid
    int columns;
    int rows;

    private static struct Push
    {
        uint gridWidth;
        uint gridHeight;
        uint texOffsetX;
        uint texOffsetY;
        uint texWidth;
        uint texHeight;
        uint samples;
    }

    this(LogicalDevice device, PipelineFactory pipelines, int columns, int rows, size_t viewCount = 1)
    in(columns > 0 && rows > 0)
    in(viewCount > 0)
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
            binding(2, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE),
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
        pool = VkObj!VkDescriptorPool(device.createDescriptorPool(bindings, cast(uint) (8 * viewCount)), device.releaseQueue);

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

        VkImageCreateInfo gridInfo = {
            sType: VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            imageType: VK_IMAGE_TYPE_2D,
            format: VK_FORMAT_R32_SFLOAT,
            tiling: VK_IMAGE_TILING_OPTIMAL,
            extent: VkExtent3D(cast(uint) columns, cast(uint) rows, 1),
            mipLevels: 1,
            arrayLayers: 1,
            samples: VK_SAMPLE_COUNT_1_BIT,
            usage: VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
        };

        grids.length = viewCount;

        foreach(ref grid; grids)
        {
            grid.buffer = device.create!MemoryBufferMappedToCPU(
                cast(size_t) columns * rows * float.sizeof,
                VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            );
            grid.image = device.create!ImageMemory(gridInfo, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

            VkImageViewCreateInfo viewInfo = {
                sType: VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                viewType: VK_IMAGE_VIEW_TYPE_2D,
                format: VK_FORMAT_R32_SFLOAT,
                subresourceRange: VkImageSubresourceRange(
                    aspectMask: VK_IMAGE_ASPECT_COLOR_BIT,
                    baseMipLevel: 0,
                    levelCount: 1,
                    baseArrayLayer: 0,
                    layerCount: 1,
                ),
                image: grid.image.image,
            };
            grid.viewObj = VkObj!VkImageView(device.releaseQueue, viewInfo);
        }

        // The kernel writes them and the cull kernel samples them, so they stay general
        auto commandPool = device.createCommandPool();
        auto buffers = commandPool.allocateBuffers(1);
        commandPool.recordOneTimeAndSubmit(buffers[0], (VkCommandBuffer buf) {
            foreach(ref grid; grids)
                transitionImageLayout(
                    buf, grid.image.image,
                    VK_IMAGE_LAYOUT_UNDEFINED,
                    VK_IMAGE_LAYOUT_GENERAL,
                    VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                    0,
                    VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                    VK_ACCESS_SHADER_WRITE_BIT,
                    0u, 1u,
                    VK_IMAGE_ASPECT_COLOR_BIT,
                );
        });
        destroy(commandPool);
    }

    ~this()
    {
        foreach(ref grid; grids)
        {
            if(grid.buffer)
            {
                destroy(grid.buffer);
                grid.buffer = null;
            }

            if(grid.viewObj.isAlive())
                destroy(grid.viewObj);

            if(grid.image)
            {
                destroy(grid.image);
                grid.image = null;
            }
        }

        if(sampler)
        {
            vkDestroySampler(device, sampler, device.alloc);
            sampler = null;
        }
    }

    /// Records the downsample of one view's rectangle of the depth image
    void record(
        VkCommandBuffer buf,
        VkImage depthImage,
        VkImageView depth,
        VkExtent2D size,
        uint samples,
        size_t view = 0,
        VkRect2D area = VkRect2D.init,
    )
    {
        if(view >= grids.length)
            return;

        if(area.extent.width == 0 || area.extent.height == 0)
            area = VkRect2D(offset: VkOffset2D(0, 0), extent: size);

        if(area.extent.width == 0 || area.extent.height == 0)
            return;

        if(columns > area.extent.width || rows > area.extent.height)
            return;

        if(pipeline is null)
        {
            auto cfg = pipelines.acquireCompute(key);
            pipeline = cfg.pipeline;
            layout = cfg.pipelineLayout;
        }

        auto grid = &grids[view];
        auto found = depth in grid.sets;

        if(found is null)
        {
            auto created = device.allocateDescriptorSet(pool.vk, setLayout);

            VkDescriptorBufferInfo info = VkDescriptorBufferInfo(grid.buffer.buf, 0, VK_WHOLE_SIZE);
            VkDescriptorImageInfo image = VkDescriptorImageInfo(
                imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                imageView: depth,
                sampler: sampler,
            );
            VkDescriptorImageInfo target = VkDescriptorImageInfo(
                imageLayout: VK_IMAGE_LAYOUT_GENERAL,
                imageView: grid.viewObj.vk,
            );

            scope VkWriteDescriptorSet[] writes = [
                imageWriteDescriptor(created, 0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, image),
                bufferWriteDescriptor(created, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, info),
                imageWriteDescriptor(created, 2, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, target),
            ];

            device.updateDescriptorSets(writes);

            grid.sets[depth] = created;
            found = depth in grid.sets;
        }

        VkDescriptorSet set = *found;

        VkPipelineStageFlags afterDepthWrites =
            VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
        VkPipelineStageFlags computeStage = VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
        VkAccessFlags depthWrite = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        VkAccessFlags shaderRead = VK_ACCESS_SHADER_READ_BIT;
        VkAccessFlags depthReadWrite =
            VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

        transitionImageLayout(
            buf, depthImage,
            VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            afterDepthWrites,
            depthWrite,
            computeStage,
            shaderRead,
            0u, 1u,
            depthStencilAspect,
        );

        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
        vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, null);

        const push = Push(
            gridWidth: cast(uint) columns,
            gridHeight: cast(uint) rows,
            texOffsetX: cast(uint) area.offset.x,
            texOffsetY: cast(uint) area.offset.y,
            texWidth: area.extent.width,
            texHeight: area.extent.height,
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
                buffer: grid.buffer.buf,
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
            depthStencilAspect,
        );

        grid.filled = true;
    }

    /// The grid of one view as an image, for a kernel that samples it
    VkImageView view(size_t view = 0)
    {
        assert(view < grids.length);
        return grids[view].viewObj.vk;
    }

    /// Sampler that reads a grid without filtering
    VkSampler readSampler() => sampler;

    /// Copies one view's last grid into `cells`; false when no frame wrote it
    bool read(float[] cells, size_t view = 0) const
    {
        assert(view < grids.length);

        if(!grids[view].filled || cells.length < columns * rows)
            return false;

        const values = cast(const(float)[]) grids[view].buffer.cpuBuf;
        cells[0 .. columns * rows] = values[0 .. columns * rows];

        return true;
    }
}
