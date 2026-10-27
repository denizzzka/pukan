module pukan.material;

import core.atomic: atomicOp;
import core.sync.mutex: Mutex;
import dlib.math: Vector3f, Vector4f, Vector4i;
import pukan.vulkan;
import pukan.vulkan.bindings;
import std.typecons: BitFlags;

enum MaterialMode: uint
{
    unlit,
    lit,
    normalsDebug,
}

enum MaterialFlag: uint
{
    vertexColor = 1u << 0,
    baseColorTexture = 1u << 1,
}

alias MaterialFlags = BitFlags!MaterialFlag;

// Array elements in std140/std430 are 16-byte aligned, so the D and GLSL
// layouts must match exactly.
struct Material
{
    Vector4f baseColorFactor = Vector4f(1, 1, 1, 1);
    Vector4f emissiveFactor = Vector4f(0, 0, 0, 0);
    Vector4i params = Vector4i(0, 0, 0, 0);

    this(Vector3f color, MaterialMode mode = MaterialMode.lit, MaterialFlags flags = MaterialFlags.init)
    {
        baseColorFactor = Vector4f(color.x, color.y, color.z, 1);
        params = Vector4i(cast(int) mode, cast(int) cast(uint) flags, 0, 0);
    }

    @property MaterialMode mode() const
    {
        return cast(MaterialMode) params.x;
    }

    @property void mode(MaterialMode value)
    {
        params.x = cast(int) value;
    }

    @property MaterialFlags flags() const
    {
        return MaterialFlags(cast(MaterialFlag) params.y);
    }

    @property void flags(MaterialFlags value)
    {
        params.y = cast(int) cast(uint) value;
    }
}

static assert(Material.sizeof == 48);

struct MaterialBlock
{
    Material material;
}

/// Material uniforms of all meshes, one slot per mesh
final class MaterialBuffer
{
    private LogicalDevice device;
    private TransferBuffer[] chunks;
    private size_t chunkCapacity;
    private size_t slotSize;
    private shared size_t used;
    private Mutex chunkMutex;

    this(LogicalDevice device, size_t chunkCapacity = 16)
    in(chunkCapacity > 0)
    {
        this.device = device;
        this.chunkCapacity = chunkCapacity;

        const alignment = cast(size_t) device.physicalDevice.properties.limits.minUniformBufferOffsetAlignment;
        slotSize = alignment > 1
            ? (MaterialBlock.sizeof + alignment - 1) / alignment * alignment
            : MaterialBlock.sizeof;

        chunkMutex = new Mutex;
    }

    ~this()
    {
        foreach(chunk; chunks)
            if(chunk)
                destroy(chunk);
    }

    /// Reserves a slot, adding a chunk when the last one fills up.
    size_t addSlot()
    {
        const slot = atomicOp!"+="(used, 1);
        const chunkIndex = slot / chunkCapacity;

        synchronized(chunkMutex)
        {
            while(chunkIndex >= chunks.length)
                chunks ~= device.create!TransferBuffer(
                    chunkCapacity * slotSize,
                    VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                );
        }

        return slot;
    }

    ref MaterialBlock content(size_t slot)
    {
        auto chunk = chunkAt(slot);

        return *cast(MaterialBlock*) (cast(ubyte*) chunk.cpuBuf.ptr + (slot % chunkCapacity) * slotSize);
    }

    VkDescriptorBufferInfo info(size_t slot)
    {
        auto chunk = chunkAt(slot);

        return VkDescriptorBufferInfo(
            buffer: chunk.gpuBuffer,
            offset: (slot % chunkCapacity) * slotSize,
            range: MaterialBlock.sizeof,
        );
    }

    void recordUpload(VkCommandBuffer commandBuffer)
    {
        TransferBuffer[] snapshot;

        synchronized(chunkMutex)
            snapshot = chunks;

        foreach(chunk; snapshot)
            chunk.recordUpload(commandBuffer);
    }

    private TransferBuffer chunkAt(size_t slot)
    {
        TransferBuffer chunk;

        synchronized(chunkMutex)
            chunk = chunks[slot / chunkCapacity];

        assert(chunk !is null);

        return chunk;
    }
}
