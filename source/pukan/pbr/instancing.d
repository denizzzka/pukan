module pukan.pbr.instancing;

import dlib.math: Matrix4x4f;
import pukan.vulkan;
import pukan.vulkan.bindings;

/// Destination of one instanced draw inside an arena chunk
struct InstanceBatch
{
    VkBuffer buffer;
    VkDeviceSize size;
    uint firstInstance;
    uint count;
}

/// Per-frame transforms, uploaded once and read as instance vertex attributes
final class InstanceArena
{
    private static struct Chunk
    {
        MemoryBufferMappedToCPU buffer;
        size_t capacity;
        size_t used;
    }

    private LogicalDevice device;
    private Chunk[] chunks;
    private size_t chunkCapacity;

    this(LogicalDevice device, size_t chunkCapacity = 4096)
    in(chunkCapacity > 0)
    {
        this.device = device;
        this.chunkCapacity = chunkCapacity;
    }

    ~this()
    {
        foreach(ref chunk; chunks)
            destroy(chunk.buffer);
    }

    void reset()
    {
        foreach(ref chunk; chunks)
            chunk.used = 0;
    }

    /// Copies the transforms into a chunk with room for all of them
    InstanceBatch append(const Matrix4x4f[] matrices)
    in(matrices.length > 0)
    {
        Chunk* target;

        foreach(ref chunk; chunks)
            if(chunk.capacity - chunk.used >= matrices.length)
            {
                target = &chunk;
                break;
            }

        if(target is null)
        {
            chunks ~= Chunk();
            target = &chunks[$ - 1];

            const capacity = matrices.length > chunkCapacity ? matrices.length : chunkCapacity;
            target.buffer = device.create!MemoryBufferMappedToCPU(
                capacity * Matrix4x4f.sizeof,
                VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            );
            target.capacity = capacity;
        }

        const first = target.used;
        auto destination = cast(Matrix4x4f[]) target.buffer.cpuBuf;
        destination[first .. first + matrices.length] = matrices;
        target.used += matrices.length;

        return InstanceBatch(
            buffer: target.buffer.buf,
            size: target.capacity * Matrix4x4f.sizeof,
            firstInstance: cast(uint) first,
            count: cast(uint) matrices.length,
        );
    }
}

/// Arena of the frame being recorded; `Scene` installs and resets it
InstanceArena currentInstanceArena;
