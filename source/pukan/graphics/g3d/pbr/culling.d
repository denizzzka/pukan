module pukan.graphics.g3d.pbr.culling;

import dlib.math: Matrix4x4f, Vector4f;
import pukan.graphics.common.shaders: shaderStage;
import pukan.vulkan.bindings;
import pukan.vulkan.descriptors: bufferWriteDescriptor;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: MemoryBufferMappedToCPU;
import pukan.vulkan.pipelines: PipelineFactory, PipelineKey;
import pukan.vulkan.resources.vkobj: VkObj;
import pukan.vulkan.requirements: Requirement;
import std.meta: AliasSeq;

/// One instance as the cull kernel reads it
struct CullInstance
{
    /// Clip-space transform of the part
    Matrix4x4f mvp;
    /// Bounds in the part's space; `w` marks a part without bounds
    Vector4f boundsMin;
    Vector4f boundsMax;
}

/// Input copy of one mesh's instances; the levels of the mesh share it
struct CullInstances
{
    uint offset;
    uint count;
}

/// What the kernel left for one level: its packed matrices and the draw command
struct CullBatch
{
    VkDeviceSize visibleOffset;
    /// Bytes the kept matrices may occupy, from the batch offset
    VkDeviceSize visibleSize;
    VkDeviceSize argsOffset;
    /// Element offset of this batch in the instance list
    uint instanceOffset;
    /// Instances the kernel considers for this batch
    uint instances;
}

/// One frame's cull kernel, its memory and its descriptor set
final class CullFrame
{
    public alias requirements = AliasSeq!(
        Requirement!(VkPhysicalDeviceVulkan12Features.drawIndirectCount),
        Requirement!(VkPhysicalDeviceLimits.maxComputeWorkGroupInvocations, workgroupSize),
    );

    /// Instances one workgroup takes
    enum workgroupSize = 64;
    /// Draw command words: the five of the command and the kept count
    private enum argsWords = 6;
    private enum argsSize = argsWords * uint.sizeof;

    private LogicalDevice device;
    private PipelineFactory pipelines;
    private PipelineKey key;
    private VkPipelineLayout layout;
    private VkDescriptorSetLayout setLayout;
    private VkDescriptorSet set;
    private VkObj!VkDescriptorPool pool;
    private VkPipeline pipeline;

    private MemoryBufferMappedToCPU instanceBuf;
    private MemoryBufferMappedToCPU visibleBuf;
    private MemoryBufferMappedToCPU argsBuf;
    private size_t instanceUsed;
    private size_t visibleUsed;
    private size_t argsUsed;
    /// Set when a buffer moved, so the next dispatch takes a fresh set
    private bool setDirty;
    /// Buffers a recorded frame may still read; freed at the next reset
    private MemoryBufferMappedToCPU[] retired;

    this(LogicalDevice device, PipelineFactory pipelines)
    {
        device.ensureEnabled!requirements("CullFrame");

        this.device = device;
        this.pipelines = pipelines;

        auto bindings = cullBindings();
        auto declared = pipelines.declareCompute(shaderStage!"instance_cull.spv"(
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
        // Room for a level of cells, so the buffers rarely move
        instanceBuf = device.create!MemoryBufferMappedToCPU(4 << 20,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        visibleBuf = device.create!MemoryBufferMappedToCPU(4 << 20,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        argsBuf = device.create!MemoryBufferMappedToCPU(1 << 20,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT);

        // A moved buffer needs a set nobody has bound yet, so the pool keeps room
        pool = VkObj!VkDescriptorPool(device.createDescriptorPool(bindings, 512), device.releaseQueue);
        set = device.allocateDescriptorSet(pool.vk, declared.setLayout);
        writeSet();
    }

    ~this()
    {
        if(instanceBuf)
            destroy(instanceBuf);

        if(visibleBuf)
            destroy(visibleBuf);

        if(argsBuf)
            destroy(argsBuf);

        foreach(buffer; retired)
            destroy(buffer);
    }

    /// Where the kernel puts the matrices and commands it keeps
    VkBuffer visibleBuffer() => visibleBuf.buf;
    VkBuffer argsBuffer() => argsBuf.buf;

    /// Forgets the batches of the previous frame; what it replaced waits for
    /// the frames still in flight
    void reset()
    {
        foreach(buffer; retired)
            device.releaseQueue.retireHolder(buffer);

        retired = null;
        instanceUsed = 0;
        visibleUsed = 0;
        argsUsed = 0;
    }

    /// Copies the instances of one mesh, so its levels all read one list
    CullInstances reserveInstances(scope const(CullInstance)[] instances)
    in(instances.length > 0)
    {
        const instanceBytes = instances.length * CullInstance.sizeof;
        auto grown = grow(instanceBuf, instanceUsed + instanceBytes);

        if(grown !is instanceBuf)
        {
            instanceBuf = grown;
            setDirty = true;
        }

        const first = instanceUsed / CullInstance.sizeof;
        auto destination = cast(CullInstance*) instanceBuf.cpuBuf.ptr;
        destination[first .. first + instances.length] = instances;

        instanceUsed += instanceBytes;

        return CullInstances(cast(uint) first, cast(uint) instances.length);
    }

    /// Prepares the output and the draw command of one level
    CullBatch reserveLevel(CullInstances instances, uint indexCount)
    {
        const visibleBytes = instances.count * Matrix4x4f.sizeof;
        auto visible = grow(visibleBuf, visibleUsed + visibleBytes);
        auto args = grow(argsBuf, argsUsed + argsSize);

        if(visible !is visibleBuf || args !is argsBuf)
        {
            visibleBuf = visible;
            argsBuf = args;
            setDirty = true;
        }

        const wordsAt = argsUsed / uint.sizeof;
        auto words = cast(uint*) argsBuf.cpuBuf.ptr;
        words[wordsAt .. wordsAt + argsWords] = [
            indexCount,
            0, // instanceCount; the indirect count supplies it
            0, // firstIndex
            0, // vertexOffset
            0, // firstInstance
            0, // unused, keeps the command a whole number of cachelines
        ];

        auto batch = CullBatch(
            visibleOffset: visibleUsed,
            visibleSize: visibleBytes,
            argsOffset: argsUsed,
            instanceOffset: instances.offset,
            instances: cast(uint) instances.count,
        );

        visibleUsed += visibleBytes;
        argsUsed += argsSize;

        return batch;
    }

    /// Runs the kernel over the instance list, keeping the ones in the depth range
    void dispatch(VkCommandBuffer buf, CullInstances instances, CullBatch batch, float minDepth, float maxDepth)
    {
        if(pipeline is null)
        {
            auto cfg = pipelines.acquireCompute(key);
            pipeline = cfg.pipeline;
            layout = cfg.pipelineLayout;
        }

        if(setDirty)
        {
            // A set the recording buffer already holds cannot be updated, so
            // the kernel gets one that nothing has bound
            set = device.allocateDescriptorSet(pool.vk, setLayout);
            writeSet();
            setDirty = false;
        }

        VkBufferMemoryBarrier[2] readable = [
            hostToShaderBarrier(instanceBuf.buf),
            hostToShaderBarrier(argsBuf.buf),
        ];

        vkCmdPipelineBarrier(
            buf,
            VK_PIPELINE_STAGE_HOST_BIT,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            0, null,
            cast(uint) readable.length, readable.ptr,
            0, null,
        );

        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);

        vkCmdBindDescriptorSets(
            buf,
            VK_PIPELINE_BIND_POINT_COMPUTE,
            layout,
            0,
            1,
            &set,
            0,
            null,
        );

        const push = Push(
            instanceOffset: instances.offset,
            visibleOffset: cast(uint)(batch.visibleOffset / Matrix4x4f.sizeof),
            argsIndex: cast(uint)(batch.argsOffset / uint.sizeof),
            instanceCount: instances.count,
            minDepth: minDepth,
            maxDepth: maxDepth,
        );

        vkCmdPushConstants(buf, layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, push.sizeof, &push);

        vkCmdDispatch(buf, (instances.count + workgroupSize - 1) / workgroupSize, 1, 1);

        VkBufferMemoryBarrier[2] written = [
            shaderToVertexBarrier(visibleBuf.buf),
            shaderToIndirectBarrier(argsBuf.buf),
        ];

        vkCmdPipelineBarrier(
            buf,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
            0,
            0, null,
            cast(uint) written.length, written.ptr,
            0, null,
        );
    }

    private MemoryBufferMappedToCPU grow(MemoryBufferMappedToCPU buffer, size_t needed)
    {
        if(buffer && buffer.cpuBuf.length >= needed)
            return buffer;

        // Headroom, so a cell that arrives does not force a move every frame
        const grown = needed + needed / 2;
        const capacity = grown < 4096 ? 4096 : grown;

        auto replaced = device.create!MemoryBufferMappedToCPU(
            capacity,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
                | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT
                | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT,
        );

        // Batches reserved before the move still read their offsets, so the
        // bytes already written have to come along
        if(buffer)
        {
            replaced.cpuBuf[0 .. buffer.cpuBuf.length] = buffer.cpuBuf;
            retired ~= buffer;
        }

        return replaced;
    }

    /// Points the kernel at the three frame buffers
    private void writeSet()
    {
        VkDescriptorBufferInfo[3] infos = [
            VkDescriptorBufferInfo(instanceBuf.buf, 0, VK_WHOLE_SIZE),
            VkDescriptorBufferInfo(visibleBuf.buf, 0, VK_WHOLE_SIZE),
            VkDescriptorBufferInfo(argsBuf.buf, 0, VK_WHOLE_SIZE),
        ];

        VkWriteDescriptorSet[] writes =
        [
            bufferWriteDescriptor(set, 0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, infos[0]),
            bufferWriteDescriptor(set, 1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, infos[1]),
            bufferWriteDescriptor(set, 2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, infos[2]),
        ];

        device.updateDescriptorSets(writes);
    }

    private static VkDescriptorSetLayoutBinding[] cullBindings()
    {
        VkDescriptorSetLayoutBinding binding(uint index) => VkDescriptorSetLayoutBinding(
            binding: index,
            descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            descriptorCount: 1,
            stageFlags: VK_SHADER_STAGE_COMPUTE_BIT,
        );

        return [binding(0), binding(1), binding(2)];
    }

    private VkBufferMemoryBarrier hostToShaderBarrier(VkBuffer buffer)
    {
        return VkBufferMemoryBarrier(
            sType: VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            srcAccessMask: VK_ACCESS_HOST_WRITE_BIT,
            dstAccessMask: VK_ACCESS_SHADER_READ_BIT,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            buffer: buffer,
            offset: 0,
            size: VK_WHOLE_SIZE,
        );
    }

    private VkBufferMemoryBarrier shaderToVertexBarrier(VkBuffer buffer)
    {
        return VkBufferMemoryBarrier(
            sType: VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            srcAccessMask: VK_ACCESS_SHADER_WRITE_BIT,
            dstAccessMask: VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            buffer: buffer,
            offset: 0,
            size: VK_WHOLE_SIZE,
        );
    }

    private VkBufferMemoryBarrier shaderToIndirectBarrier(VkBuffer buffer)
    {
        return VkBufferMemoryBarrier(
            sType: VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            srcAccessMask: VK_ACCESS_SHADER_WRITE_BIT,
            dstAccessMask: VK_ACCESS_INDIRECT_COMMAND_READ_BIT,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            buffer: buffer,
            offset: 0,
            size: VK_WHOLE_SIZE,
        );
    }

    private struct Push
    {
        uint instanceOffset;
        uint visibleOffset;
        uint argsIndex;
        uint instanceCount;
        float minDepth;
        float maxDepth;
    }
}

/// Cull frame of the frame being recorded; `Scene` installs and resets it
CullFrame currentCullFrame;
