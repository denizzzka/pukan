module pukan.primitives_tree.sphere;

import dlib.math: Matrix4x4f, Vector3f, Vector4f;
import pukan.primitives_tree: DrawablePrimitive;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.requirements: Requirement;
import std.meta: AliasSeq;
import std.typecons: BitFlags;

enum SphereGroupFlag: uint
{
    normals = 1u << 0,
}

alias SphereGroupFlags = BitFlags!SphereGroupFlag;

struct SphereVertex
{
    Vector3f pos;

    static auto getBindingDescriptions()
    {
        return [
            VkVertexInputBindingDescription(
                binding: 0,
                stride: pos.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
            VkVertexInputBindingDescription(
                binding: 1,
                stride: 4 * float.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_INSTANCE,
            ),
        ];
    }

    static auto getAttributeDescriptions()
    {
        return [
            VkVertexInputAttributeDescription(
                binding: 0,
                location: 0,
                format: VK_FORMAT_R32G32B32_SFLOAT,
                offset: 0,
            ),
            VkVertexInputAttributeDescription(
                binding: 1,
                location: 1,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: 0,
            ),
        ];
    }
}

struct SphereGroup
{
    Vector3f color;
    SphereGroupFlags flags;
}

struct SphereInstance
{
    Vector3f center;
    float radius;
    uint groupIndex;
}

struct SphereLod
{
    float maxEdgePx = 5.0f;
    uint maxLevel = 6;
}

private struct SphereLevel
{
    uint vertexOffset;
    uint indexOffset;
    uint indexCount;
}

private struct ClassifyPush
{
    Matrix4x4f viewModel;
    float tanX;
    float tanY;
    float focal;
    float nearPlane;
    float farPlane;
    float maxEdge;
    float minEdge;
    uint sphereCount;
    uint groupCount;
    uint levelCount;
    uint maxLevel;
}

private final class SphereKernel : Compute
{
    this(
        LogicalDevice device,
        VkDescriptorSetLayoutBinding[] bindings,
        ubyte[] spv,
        VkPushConstantRange range,
    )
    {
        super(device, bindings, spv, range);
    }

    void bind(uint binding, VkDescriptorType type, ref VkDescriptorBufferInfo info)
    {
        bindBuffer(binding, type, info);
    }

    void commit()
    {
        commitDescriptorWrites();
    }

    void run(VkCommandBuffer cb, const(void)* pushConstants, uint groups)
    {
        dispatch(cb, pushConstants, groups, 1, 1);
    }
}

private final class IcosphereGenerator : Compute
{
    private enum workgroupSize = 64;

    private struct Params
    {
        uint level;
        uint vertexOffset;
        uint indexOffset;
    }

    private SphereLevel[] levels;
    private MemoryBuffer vertexBuffer;
    private MemoryBuffer indexBuffer;
    private bool generated;

    this(LogicalDevice device, uint maxLevel)
    {
        VkDescriptorSetLayoutBinding[] layoutBindings = [
            VkDescriptorSetLayoutBinding(
                binding: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
            ),
            VkDescriptorSetLayoutBinding(
                binding: 1,
                descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
            ),
        ];

        super(
            device,
            layoutBindings,
            cast(ubyte[]) import("icosphere.spv"),
            VkPushConstantRange(
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
                offset: 0,
                size: Params.sizeof,
            ),
        );

        uint totalVertices;
        foreach(level; 0 .. maxLevel + 1)
        {
            const count = 60u * (1u << (2 * level));
            levels ~= SphereLevel(totalVertices, totalVertices, count);
            totalVertices += count;
        }

        vertexBuffer = createDeviceBuffer(
            device,
            totalVertices * SphereVertex.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        indexBuffer = createDeviceBuffer(
            device,
            totalVertices * uint.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        );

        VkDescriptorBufferInfo vertexInfo = { buffer: vertexBuffer.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo indexInfo = { buffer: indexBuffer.buf, offset: 0, range: VK_WHOLE_SIZE };
        bindBuffer(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, vertexInfo);
        bindBuffer(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, indexInfo);
        commitDescriptorWrites();
    }

    ~this()
    {
        if(vertexBuffer)
            destroy(vertexBuffer);

        if(indexBuffer)
            destroy(indexBuffer);
    }

    void generate(CommandPool commandPool, VkCommandBuffer commandBuffer)
    {
        if(generated)
            return;

        commandPool.recordOneTimeAndSubmit(commandBuffer, (cb) {
            foreach(level, lvl; levels)
            {
                auto params = Params(cast(uint) level, lvl.vertexOffset, lvl.indexOffset);
                dispatch(
                    cb,
                    &params,
                    (lvl.indexCount + workgroupSize - 1) / workgroupSize,
                    1,
                    1,
                );
            }

            VkBufferMemoryBarrier[2] barriers = [
                computeToVertexBarrier(vertexBuffer.buf),
                computeToVertexBarrier(indexBuffer.buf),
            ];
            vkCmdPipelineBarrier(
                cb,
                VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                VK_PIPELINE_STAGE_VERTEX_INPUT_BIT,
                0,
                0, null,
                2, barriers.ptr,
                0, null,
            );
        });

        generated = true;
    }

    SphereLevel level(uint level) const
    {
        return levels[level];
    }

    VkBuffer vertexBufferHandle() => vertexBuffer.buf;
    VkBuffer indexBufferHandle() => indexBuffer.buf;
}

private MemoryBuffer createDeviceBuffer(LogicalDevice device, size_t size, VkBufferUsageFlags usage)
{
    VkBufferCreateInfo info = {
        sType: VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        size: size,
        usage: usage,
        sharingMode: VK_SHARING_MODE_EXCLUSIVE,
    };

    return device.create!MemoryBuffer(info, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
}

private VkBufferMemoryBarrier computeToVertexBarrier(VkBuffer buffer)
{
    return VkBufferMemoryBarrier(
        sType: VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        srcAccessMask: VK_ACCESS_SHADER_WRITE_BIT,
        dstAccessMask: VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | VK_ACCESS_INDEX_READ_BIT,
        srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
        buffer: buffer,
        offset: 0,
        size: VK_WHOLE_SIZE,
    );
}

class SphereRenderer : DrawablePrimitive
{
    private enum frameBuckets = 64;
    private enum paletteSize = 16;

    private alias requirements = AliasSeq!(
        Requirement!(VkQueueFamilyProperties.queueFlags, VK_QUEUE_COMPUTE_BIT),
        Requirement!(VkPhysicalDeviceLimits.maxComputeWorkGroupInvocations, 64),
        Requirement!(VkPhysicalDeviceFeatures.drawIndirectFirstInstance),
        Requirement!(VkPhysicalDeviceFeatures.multiDrawIndirect),
        Requirement!(VkPhysicalDeviceLimits.maxDrawIndirectCount, 64),
    );

    private LogicalDevice device;
    private SphereLod lod;
    private uint instanceCount;
    private uint groupCount;
    private uint levelCount;
    private uint bucketCount;

    GraphicsPipelineCfg pipelineCfg;
    private PoolAndLayoutInfo graphicsPool;
    private VkDescriptorSet graphicsSet;
    private MemoryBufferMappedToCPU paletteBuffer;

    private IcosphereGenerator generator;
    private SphereKernel classify;
    private SphereKernel scan;
    private SphereKernel scatter;

    private TransferBuffer sourceCenters;
    private TransferBuffer sourceColors;
    private TransferBuffer levels;
    private TransferBuffer commands;
    private MemoryBuffer sphereBuckets;
    private MemoryBuffer counts;
    private MemoryBuffer offsets;
    private MemoryBuffer cursors;
    private MemoryBuffer bucketCenters;
    private MemoryBuffer bucketColors;

    private ClassifyPush classifyPush;
    private bool uploaded;
    private bool prepared;

    this(
        LogicalDevice device,
        PipelineFactory pipelines,
        ShaderInfo[] shaderStages,
        RenderPass renderPass,
        SphereLod lod = SphereLod(),
    )
    {
        this.device = device;
        this.lod = lod;
        this.levelCount = lod.maxLevel + 1;

        const technique = pipelines.declare(RenderTechnique(
            name: "spheres",
            stages: shaderStages,
            vertexBindings: SphereVertex.getBindingDescriptions,
            vertexAttributes: SphereVertex.getAttributeDescriptions,
        ), 1);

        graphicsPool = pipelines.poolAndLayout(technique);
        graphicsSet = device.allocateDescriptorSet(graphicsPool);

        paletteBuffer = device.create!MemoryBufferMappedToCPU(
            paletteSize * Vector4f.sizeof,
            VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        );

        pipelineCfg = pipelines.acquire(technique, renderPass, 1);

        generator = new IcosphereGenerator(device, lod.maxLevel);
    }

    ~this()
    {
        if(classify)
            destroy(classify);
        if(scan)
            destroy(scan);
        if(scatter)
            destroy(scatter);
        if(generator)
            destroy(generator);

        if(sourceCenters)
            destroy(sourceCenters);
        if(sourceColors)
            destroy(sourceColors);
        if(levels)
            destroy(levels);
        if(commands)
            destroy(commands);
        if(sphereBuckets)
            destroy(sphereBuckets);
        if(counts)
            destroy(counts);
        if(offsets)
            destroy(offsets);
        if(cursors)
            destroy(cursors);
        if(bucketCenters)
            destroy(bucketCenters);
        if(bucketColors)
            destroy(bucketColors);
        if(paletteBuffer)
            destroy(paletteBuffer);
    }

    void setInstances(SphereInstance[] instances, SphereGroup[] groups)
    in(instances.length > 0)
    in(groups.length > 0 && groups.length <= paletteSize)
    {
        import core.stdc.string: memset;

        assert(!uploaded);
        assert(groups.length * levelCount <= frameBuckets);

        instanceCount = cast(uint) instances.length;
        groupCount = cast(uint) groups.length;
        bucketCount = groupCount * levelCount;

        foreach(ref instance; instances)
            assert(instance.groupIndex < groupCount);

        sourceCenters = device.create!TransferBuffer(
            instances.length * Vector4f.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );
        sourceColors = device.create!TransferBuffer(
            instances.length * uint.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );
        levels = device.create!TransferBuffer(
            instances.length * uint.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );
        commands = device.create!TransferBuffer(
            frameBuckets * VkDrawIndexedIndirectCommand.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT,
        );

        sphereBuckets = createDeviceBuffer(device, instances.length * uint.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        counts = createDeviceBuffer(device, frameBuckets * uint.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        offsets = createDeviceBuffer(device, frameBuckets * uint.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        cursors = createDeviceBuffer(device, frameBuckets * uint.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        bucketCenters = createDeviceBuffer(device, instances.length * Vector4f.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        bucketColors = createDeviceBuffer(device, instances.length * uint.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);

        {
            auto centers = cast(Vector4f[]) sourceCenters.cpuBuf;
            auto colors = cast(uint[]) sourceColors.cpuBuf;
            foreach(i, ref instance; instances)
            {
                centers[i] = Vector4f(instance.center.x, instance.center.y, instance.center.z, instance.radius);
                colors[i] = instance.groupIndex;
            }
        }

        memset(levels.cpuBuf.ptr, 0, levels.cpuBuf.length);

        {
            memset(commands.cpuBuf.ptr, 0, commands.cpuBuf.length);
            auto indirect = cast(VkDrawIndexedIndirectCommand[]) commands.cpuBuf;
            foreach(group; 0 .. groupCount)
            {
                foreach(level; 0 .. levelCount)
                {
                    const lvl = generator.level(level);
                    indirect[group * levelCount + level] = VkDrawIndexedIndirectCommand(
                        indexCount: lvl.indexCount,
                        instanceCount: 0,
                        firstIndex: lvl.indexOffset,
                        vertexOffset: lvl.vertexOffset,
                        firstInstance: 0,
                    );
                }
            }
        }

        {
            auto paletteData = cast(Vector4f[]) paletteBuffer.cpuBuf;
            foreach(i, ref group; groups)
                paletteData[i] = Vector4f(group.color.x, group.color.y, group.color.z, cast(float) cast(uint) group.flags);
            foreach(i; groups.length .. paletteSize)
                paletteData[i] = Vector4f(0.0f, 0.0f, 0.0f, 0.0f);
        }

        {
            VkDescriptorBufferInfo paletteInfo = { buffer: paletteBuffer.buf, offset: 0, range: paletteSize * Vector4f.sizeof };
            VkDescriptorBufferInfo colorsInfo = { buffer: bucketColors.buf, offset: 0, range: VK_WHOLE_SIZE };
            VkWriteDescriptorSet[] writes = [
                bufferWriteDescriptor(graphicsSet, 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, paletteInfo),
                bufferWriteDescriptor(graphicsSet, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, colorsInfo),
            ];
            device.updateDescriptorSets(writes);
        }

        createKernels();
    }

    private void createKernels()
    {
        VkDescriptorBufferInfo centersInfo = { buffer: sourceCenters.gpuBuffer.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo colorsInfo = { buffer: sourceColors.gpuBuffer.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo levelsInfo = { buffer: levels.gpuBuffer.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo bucketsInfo = { buffer: sphereBuckets.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo countsInfo = { buffer: counts.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo offsetsInfo = { buffer: offsets.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo cursorsInfo = { buffer: cursors.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo commandsInfo = { buffer: commands.gpuBuffer.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo bucketCentersInfo = { buffer: bucketCenters.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo bucketColorsInfo = { buffer: bucketColors.buf, offset: 0, range: VK_WHOLE_SIZE };

        classify = new SphereKernel(
            device,
            [
                VkDescriptorSetLayoutBinding(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(4, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
            ],
            cast(ubyte[]) import("sphere_classify.spv"),
            VkPushConstantRange(
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
                offset: 0,
                size: ClassifyPush.sizeof,
            ),
        );
        classify.bind(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, centersInfo);
        classify.bind(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, colorsInfo);
        classify.bind(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, levelsInfo);
        classify.bind(3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, bucketsInfo);
        classify.bind(4, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, countsInfo);
        classify.commit();

        scan = new SphereKernel(
            device,
            [
                VkDescriptorSetLayoutBinding(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
            ],
            cast(ubyte[]) import("sphere_scan.spv"),
            VkPushConstantRange(
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
                offset: 0,
                size: uint.sizeof,
            ),
        );
        scan.bind(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, countsInfo);
        scan.bind(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, offsetsInfo);
        scan.bind(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, cursorsInfo);
        scan.bind(3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, commandsInfo);
        scan.commit();

        scatter = new SphereKernel(
            device,
            [
                VkDescriptorSetLayoutBinding(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(4, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(5, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(6, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
            ],
            cast(ubyte[]) import("sphere_scatter.spv"),
            VkPushConstantRange(
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
                offset: 0,
                size: uint.sizeof,
            ),
        );
        scatter.bind(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, centersInfo);
        scatter.bind(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, colorsInfo);
        scatter.bind(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, bucketsInfo);
        scatter.bind(3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, offsetsInfo);
        scatter.bind(4, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, cursorsInfo);
        scatter.bind(5, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, bucketCentersInfo);
        scatter.bind(6, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, bucketColorsInfo);
        scatter.commit();
    }

    void setCamera(
        Matrix4x4f viewModel,
        float fovY,
        float aspect,
        uint viewportHeight,
        float nearPlane,
        float farPlane,
    )
    {
        import std.math: PI, tan;

        const tanY = tan(fovY * 0.5f * PI / 180.0f);
        const tanX = tanY * aspect;
        const focal = (viewportHeight * 0.5f) / tanY;

        classifyPush = ClassifyPush(
            viewModel: viewModel,
            tanX: tanX,
            tanY: tanY,
            focal: focal,
            nearPlane: nearPlane,
            farPlane: farPlane,
            maxEdge: lod.maxEdgePx,
            minEdge: lod.maxEdgePx * 0.5f,
            sphereCount: instanceCount,
            groupCount: groupCount,
            levelCount: levelCount,
            maxLevel: lod.maxLevel,
        );
    }

    override void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        if(instanceCount == 0)
            return;

        generator.generate(commandPool, commandBuffer);

        sourceCenters.uploadImmediate(commandPool, commandBuffer);
        sourceColors.uploadImmediate(commandPool, commandBuffer);
        levels.uploadImmediate(commandPool, commandBuffer);
        commands.uploadImmediate(commandPool, commandBuffer);

        uploaded = true;
    }

    void prepare(VkCommandBuffer buf)
    {
        prepared = false;

        if(instanceCount == 0 || !uploaded)
            return;

        vkCmdFillBuffer(buf, counts.buf, 0, frameBuckets * uint.sizeof, 0);
        bufferBarrier(
            buf,
            VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
            [counts.buf],
        );

        bufferBarrier(
            buf,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_ACCESS_SHADER_WRITE_BIT,
            VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
            [levels.gpuBuffer.buf],
        );

        const groups = (instanceCount + 63) / 64;
        classify.run(buf, &classifyPush, groups);

        bufferBarrier(
            buf,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_ACCESS_SHADER_WRITE_BIT,
            VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
            [counts.buf, sphereBuckets.buf],
        );

        uint scanFallback;
        scan.run(buf, &scanFallback, 1);

        bufferBarrier(
            buf,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_ACCESS_SHADER_WRITE_BIT,
            VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
            [offsets.buf, cursors.buf, commands.gpuBuffer.buf],
        );

        const uint sphereCount = instanceCount;
        scatter.run(buf, &sphereCount, groups);

        bufferBarrier(
            buf,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
            VK_ACCESS_SHADER_WRITE_BIT,
            VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_INDIRECT_COMMAND_READ_BIT,
            [bucketCenters.buf, bucketColors.buf, commands.gpuBuffer.buf],
        );

        prepared = true;
    }

    override void drawingBufferFilling(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f mvp)
    {
        if(instanceCount == 0 || !prepared)
            return;

        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);
        vkCmdPushConstants(
            buf,
            pipeline.pipelineLayout,
            VK_SHADER_STAGE_VERTEX_BIT,
            0,
            Matrix4x4f.sizeof,
            &mvp,
        );

        VkBuffer[2] vertexBuffers = [generator.vertexBufferHandle(), bucketCenters.buf];
        VkDeviceSize[2] offsets = [0, 0];
        vkCmdBindVertexBuffers(buf, 0, 2, vertexBuffers.ptr, offsets.ptr);
        vkCmdBindIndexBuffer(buf, generator.indexBufferHandle(), 0, VK_INDEX_TYPE_UINT32);
        vkCmdBindDescriptorSets(
            buf,
            VK_PIPELINE_BIND_POINT_GRAPHICS,
            pipeline.pipelineLayout,
            0,
            1,
            &graphicsSet,
            0,
            null,
        );
        vkCmdDrawIndexedIndirect(
            buf,
            commands.gpuBuffer.buf,
            0,
            bucketCount,
            VkDrawIndexedIndirectCommand.sizeof,
        );
    }
}

private void bufferBarrier(
    VkCommandBuffer cb,
    VkPipelineStageFlags srcStage,
    VkPipelineStageFlags dstStage,
    VkAccessFlags srcAccess,
    VkAccessFlags dstAccess,
    VkBuffer[] buffers,
)
{
    VkBufferMemoryBarrier[] barriers;
    barriers.length = buffers.length;

    foreach(i, buffer; buffers)
    {
        barriers[i] = VkBufferMemoryBarrier(
            sType: VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            srcAccessMask: srcAccess,
            dstAccessMask: dstAccess,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            buffer: buffer,
            offset: 0,
            size: VK_WHOLE_SIZE,
        );
    }

    vkCmdPipelineBarrier(
        cb,
        srcStage,
        dstStage,
        0,
        0, null,
        cast(uint) barriers.length, barriers.ptr,
        0, null,
    );
}
