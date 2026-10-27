module pukan.primitives_tree.cylinder;

import dlib.math: Matrix4x4f, Vector3f, Vector4f;
import pukan.primitives_tree: DrawablePrimitive;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.requirements: Requirement;
import std.meta: AliasSeq;
import std.typecons: BitFlags;

enum CylinderGroupFlag: uint
{
    normals = 1u << 0,
    firstCap = 1u << 1,
    secondCap = 1u << 2,
}

alias CylinderGroupFlags = BitFlags!CylinderGroupFlag;

struct CylinderInstance
{
    Vector3f p0;
    Vector3f p1;
    float radius;
    uint groupIndex;
}

struct CylinderGroup
{
    Vector3f color;
    CylinderGroupFlags flags = CylinderGroupFlags(CylinderGroupFlag.firstCap, CylinderGroupFlag.secondCap);
}

struct CylinderLod
{
    float maxEdgePx = 5.0f;
    uint maxLevel = 6;
}

struct CylinderVertex
{
    Vector3f pos;
    Vector3f normal;
}

private ShaderVertexInput vertexInput()
{
    return ShaderVertexInput(
        [
            VkVertexInputBindingDescription(
                binding: 0,
                stride: CylinderVertex.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
            VkVertexInputBindingDescription(
                binding: 1,
                stride: 4 * Vector4f.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_INSTANCE,
            ),
        ],
        [
            VkVertexInputAttributeDescription(
                binding: 0,
                location: 0,
                format: VK_FORMAT_R32G32B32_SFLOAT,
                offset: 0,
            ),
            VkVertexInputAttributeDescription(
                binding: 0,
                location: 1,
                format: VK_FORMAT_R32G32B32_SFLOAT,
                offset: Vector3f.sizeof,
            ),
            VkVertexInputAttributeDescription(
                binding: 1,
                location: 2,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: 0,
            ),
            VkVertexInputAttributeDescription(
                binding: 1,
                location: 3,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: 16,
            ),
            VkVertexInputAttributeDescription(
                binding: 1,
                location: 4,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: 32,
            ),
            VkVertexInputAttributeDescription(
                binding: 1,
                location: 5,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
                offset: 48,
            ),
        ],
    );
}

private struct CylinderLevel
{
    uint vertexOffset;
    uint indexOffset;
    uint segments;
    uint sideIndices;
    uint capIndices;
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
    uint cylinderCount;
    uint groupCount;
    uint levelCount;
    uint maxLevel;
}

private final class CylinderKernel : Compute
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

private final class CylinderMeshGenerator : Compute
{
    private enum workgroupSize = 64;

    private struct Params
    {
        uint level;
        uint vertexOffset;
        uint indexOffset;
    }

    private CylinderLevel[] levels;
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
            cast(ubyte[]) import("cylinder_mesh.spv"),
            VkPushConstantRange(
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
                offset: 0,
                size: Params.sizeof,
            ),
        );

        uint totalVertices;
        uint totalIndices;
        foreach(level; 0 .. maxLevel + 1)
        {
            const segments = 8u << level;
            levels ~= CylinderLevel(
                totalVertices,
                totalIndices,
                segments,
                6u * segments,
                3u * segments,
            );
            totalVertices += 4u * segments + 2u;
            totalIndices += 12u * segments;
        }

        vertexBuffer = createDeviceBuffer(
            device,
            totalVertices * CylinderVertex.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        indexBuffer = createDeviceBuffer(
            device,
            totalIndices * uint.sizeof,
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
                const count = 12u * lvl.segments;
                dispatch(cb, &params, (count + workgroupSize - 1) / workgroupSize, 1, 1);
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

    CylinderLevel level(uint level) const
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

class CylinderRenderer : DrawablePrimitive
{
    private enum bucketLimit = 64;
    private enum partCount = 3;
    private enum paletteSize = 16;

    private alias requirements = AliasSeq!(
        Requirement!(VkQueueFamilyProperties.queueFlags, VK_QUEUE_COMPUTE_BIT),
        Requirement!(VkPhysicalDeviceLimits.maxComputeWorkGroupInvocations, 64),
        Requirement!(VkPhysicalDeviceFeatures.drawIndirectFirstInstance),
        Requirement!(VkPhysicalDeviceFeatures.multiDrawIndirect),
        Requirement!(VkPhysicalDeviceLimits.maxDrawIndirectCount, 64),
    );

    private LogicalDevice device;
    private CylinderLod lod;
    private uint instanceCount;
    private uint groupCount;
    private uint levelCount;
    private uint bucketCount;

    GraphicsPipelineCfg pipelineCfg;
    private VkDescriptorSet graphicsSet;
    private MemoryBufferMappedToCPU paletteBuffer;

    private CylinderMeshGenerator generator;
    private CylinderKernel classify;
    private CylinderKernel scan;
    private CylinderKernel scatter;

    private TransferBuffer sourceA;
    private TransferBuffer sourceB;
    private TransferBuffer levels;
    private TransferBuffer commands;
    private MemoryBuffer buckets;
    private MemoryBuffer counts;
    private MemoryBuffer offsets;
    private MemoryBuffer cursors;
    private MemoryBuffer bucketInstances;

    private ClassifyPush classifyPush;
    private bool uploaded;
    private bool prepared;

    this(
        LogicalDevice device,
        PipelineFactory pipelines,
        RenderPass renderPass,
        CylinderLod lod = CylinderLod(),
    )
    {
        this.device = device;
        this.lod = lod;
        this.levelCount = lod.maxLevel + 1;

        const technique = pipelines.declare(RenderTechnique(
            name: "cylinders",
            stages: shaderStages(device),
            // The instance basis is left-handed, so its winding is reversed.
            state: FixedState(frontFace: VK_FRONT_FACE_COUNTER_CLOCKWISE),
        ), 1);

        auto allocator = pipelines.descriptorAllocator(technique);
        graphicsSet = allocator.allocate();

        paletteBuffer = device.create!MemoryBufferMappedToCPU(
            paletteSize * Vector4f.sizeof,
            VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        );

        pipelineCfg = pipelines.acquire(technique, renderPass, 1);

        generator = new CylinderMeshGenerator(device, lod.maxLevel);
    }

    private static ShaderInfo[] shaderStages(LogicalDevice device)
    {
        return [
            device.uploadShaderToGPU(
                cast(ubyte[]) import("cylinder_vert.spv"),
                VK_SHADER_STAGE_VERTEX_BIT,
                [
                    VkDescriptorSetLayoutBinding(
                        binding: 0,
                        descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                        descriptorCount: 1,
                        stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                    ),
                ],
                VkPushConstantRange(
                    stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                    offset: 0,
                    size: Matrix4x4f.sizeof,
                ),
                vertexInput(),
            ),
            device.uploadShaderToGPU(
                cast(ubyte[]) import("cylinder_frag.spv"),
                VK_SHADER_STAGE_FRAGMENT_BIT,
                null,
            ),
        ];
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

        if(sourceA)
            destroy(sourceA);
        if(sourceB)
            destroy(sourceB);
        if(levels)
            destroy(levels);
        if(commands)
            destroy(commands);
        if(buckets)
            destroy(buckets);
        if(counts)
            destroy(counts);
        if(offsets)
            destroy(offsets);
        if(cursors)
            destroy(cursors);
        if(bucketInstances)
            destroy(bucketInstances);
        if(paletteBuffer)
            destroy(paletteBuffer);
    }

    void setInstances(CylinderInstance[] instances, CylinderGroup[] groups)
    in(instances.length > 0)
    in(groups.length > 0 && groups.length <= paletteSize)
    {
        import core.stdc.string: memset;

        assert(!uploaded);
        assert(groups.length * levelCount <= bucketLimit);

        instanceCount = cast(uint) instances.length;
        groupCount = cast(uint) groups.length;
        bucketCount = groupCount * levelCount;

        foreach(ref instance; instances)
        {
            assert(instance.groupIndex < groupCount);
            assert(instance.radius > 0);
        }

        sourceA = device.create!TransferBuffer(
            instances.length * Vector4f.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );
        sourceB = device.create!TransferBuffer(
            instances.length * Vector4f.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );
        levels = device.create!TransferBuffer(
            instances.length * uint.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );
        commands = device.create!TransferBuffer(
            bucketLimit * partCount * VkDrawIndexedIndirectCommand.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT,
        );

        buckets = createDeviceBuffer(device, instances.length * uint.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        counts = createDeviceBuffer(device, bucketLimit * uint.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT);
        offsets = createDeviceBuffer(device, bucketLimit * uint.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        cursors = createDeviceBuffer(device, bucketLimit * uint.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        bucketInstances = createDeviceBuffer(device, instances.length * 4 * Vector4f.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

        {
            auto a = cast(Vector4f[]) sourceA.cpuBuf;
            auto b = cast(Vector4f[]) sourceB.cpuBuf;
            foreach(i, ref instance; instances)
            {
                a[i] = Vector4f(instance.p0.x, instance.p0.y, instance.p0.z, instance.radius);
                b[i] = Vector4f(instance.p1.x, instance.p1.y, instance.p1.z, cast(float) instance.groupIndex);
            }
        }

        memset(levels.cpuBuf.ptr, 0, levels.cpuBuf.length);

        {
            memset(commands.cpuBuf.ptr, 0, commands.cpuBuf.length);
            auto indirect = cast(VkDrawIndexedIndirectCommand[]) commands.cpuBuf;

            foreach(group; 0 .. groupCount)
            {
                const flags = groups[group].flags;

                foreach(level; 0 .. levelCount)
                {
                    const lvl = generator.level(level);
                    const base = (group * levelCount + level) * partCount;

                    indirect[base + 0u] = VkDrawIndexedIndirectCommand(
                        indexCount: lvl.sideIndices,
                        instanceCount: 0,
                        firstIndex: lvl.indexOffset,
                        vertexOffset: lvl.vertexOffset,
                        firstInstance: 0,
                    );
                    indirect[base + 1u] = VkDrawIndexedIndirectCommand(
                        indexCount: flags.firstCap ? lvl.capIndices : 0,
                        instanceCount: 0,
                        firstIndex: lvl.indexOffset + lvl.sideIndices,
                        vertexOffset: lvl.vertexOffset,
                        firstInstance: 0,
                    );
                    indirect[base + 2u] = VkDrawIndexedIndirectCommand(
                        indexCount: flags.secondCap ? lvl.capIndices : 0,
                        instanceCount: 0,
                        firstIndex: lvl.indexOffset + lvl.sideIndices + lvl.capIndices,
                        vertexOffset: lvl.vertexOffset,
                        firstInstance: 0,
                    );
                }
            }
        }

        {
            auto palette = cast(Vector4f[]) paletteBuffer.cpuBuf;
            foreach(i, ref group; groups)
                palette[i] = Vector4f(group.color.x, group.color.y, group.color.z, cast(float) cast(uint) group.flags);
            foreach(i; groups.length .. paletteSize)
                palette[i] = Vector4f(0.0f, 0.0f, 0.0f, 0.0f);
        }

        {
            VkDescriptorBufferInfo paletteInfo = {
                buffer: paletteBuffer.buf,
                offset: 0,
                range: paletteSize * Vector4f.sizeof,
            };
            VkWriteDescriptorSet[] writes = [
                bufferWriteDescriptor(graphicsSet, 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, paletteInfo),
            ];
            device.updateDescriptorSets(writes);
        }

        createKernels();
    }

    private void createKernels()
    {
        VkDescriptorBufferInfo aInfo = { buffer: sourceA.gpuBuffer.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo bInfo = { buffer: sourceB.gpuBuffer.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo levelsInfo = { buffer: levels.gpuBuffer.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo bucketsInfo = { buffer: buckets.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo countsInfo = { buffer: counts.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo offsetsInfo = { buffer: offsets.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo cursorsInfo = { buffer: cursors.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo commandsInfo = { buffer: commands.gpuBuffer.buf, offset: 0, range: VK_WHOLE_SIZE };
        VkDescriptorBufferInfo instancesInfo = { buffer: bucketInstances.buf, offset: 0, range: VK_WHOLE_SIZE };

        classify = new CylinderKernel(
            device,
            [
                VkDescriptorSetLayoutBinding(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(4, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
            ],
            cast(ubyte[]) import("cylinder_classify.spv"),
            VkPushConstantRange(
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
                offset: 0,
                size: ClassifyPush.sizeof,
            ),
        );
        classify.bind(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, aInfo);
        classify.bind(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, bInfo);
        classify.bind(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, levelsInfo);
        classify.bind(3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, bucketsInfo);
        classify.bind(4, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, countsInfo);
        classify.commit();

        scan = new CylinderKernel(
            device,
            [
                VkDescriptorSetLayoutBinding(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
            ],
            cast(ubyte[]) import("cylinder_scan.spv"),
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

        scatter = new CylinderKernel(
            device,
            [
                VkDescriptorSetLayoutBinding(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(4, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
                VkDescriptorSetLayoutBinding(5, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT),
            ],
            cast(ubyte[]) import("cylinder_scatter.spv"),
            VkPushConstantRange(
                stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
                offset: 0,
                size: uint.sizeof,
            ),
        );
        scatter.bind(0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, aInfo);
        scatter.bind(1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, bInfo);
        scatter.bind(2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, bucketsInfo);
        scatter.bind(3, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, offsetsInfo);
        scatter.bind(4, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, cursorsInfo);
        scatter.bind(5, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, instancesInfo);
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
            cylinderCount: instanceCount,
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

        commandPool.recordOneTimeAndSubmit(commandBuffer, (buf) {
            sourceA.recordUpload(buf);
            sourceB.recordUpload(buf);
            levels.recordUpload(buf);
            commands.recordUpload(buf);
        });

        uploaded = true;
    }

    void prepare(VkCommandBuffer buf)
    {
        prepared = false;

        if(instanceCount == 0 || !uploaded)
            return;

        vkCmdFillBuffer(buf, counts.buf, 0, bucketLimit * uint.sizeof, 0);
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
            [counts.buf, buckets.buf],
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

        const uint cylinderCount = instanceCount;
        scatter.run(buf, &cylinderCount, groups);

        bufferBarrier(
            buf,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
            VK_ACCESS_SHADER_WRITE_BIT,
            VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | VK_ACCESS_INDIRECT_COMMAND_READ_BIT,
            [bucketInstances.buf, commands.gpuBuffer.buf],
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

        VkBuffer[2] vertexBuffers = [generator.vertexBufferHandle(), bucketInstances.buf];
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
            bucketCount * partCount,
            VkDrawIndexedIndirectCommand.sizeof,
        );
    }
}
