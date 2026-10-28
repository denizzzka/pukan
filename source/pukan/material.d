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
    pbr,
}

enum MaterialFlag: uint
{
    vertexColor = 1u << 0,
    baseColorTexture = 1u << 1,
    metallicRoughnessTexture = 1u << 2,
    normalTexture = 1u << 3,
    occlusionTexture = 1u << 4,
    emissiveTexture = 1u << 5,
    derivedNormals = 1u << 6,
    vertexTangent = 1u << 7,
    specularTexture = 1u << 8,
    specularColorTexture = 1u << 9,
    clearcoatTexture = 1u << 10,
    clearcoatRoughnessTexture = 1u << 11,
    clearcoatNormalTexture = 1u << 12,
    sheenColorTexture = 1u << 13,
    sheenRoughnessTexture = 1u << 14,
    anisotropyTexture = 1u << 15,
    iridescenceTexture = 1u << 16,
    iridescenceThicknessTexture = 1u << 17,
}

alias MaterialFlags = BitFlags!MaterialFlag;

enum AlphaMode: uint
{
    opaque,
    mask,
    blend,
}

// Array elements in std140/std430 are 16-byte aligned, so the D and GLSL
// layouts must match exactly.
struct Material
{
    Vector4f baseColorFactor = Vector4f(1, 1, 1, 1);
    Vector4f emissiveFactor = Vector4f(0, 0, 0, 0);
    Vector4f metallicRoughness = Vector4f(0, 1, 1, 1); // metallic, roughness, normal scale, occlusion strength
    Vector4f alphaParams = Vector4f(0.5f, 0, 0, 0);    // x = cutoff
    Vector4i params = Vector4i(0, 0, 0, 0);            // x = mode, y = flags, z = AlphaMode
    Vector4f specular = Vector4f(1, 1, 1, 1);          // rgb = F0 color, a = strength
    Vector4f iorParams = Vector4f(1.5f, 0, 0, 0);      // x = index of refraction
    Vector4f clearcoat = Vector4f(0, 0, 1, 0);         // x = factor, y = roughness, z = normal scale
    Vector4f sheen = Vector4f(0, 0, 0, 0);             // rgb = color, a = roughness
    Vector4f anisotropy = Vector4f(0, 0, 0, 0);        // x = strength, y = rotation
    Vector4f iridescence = Vector4f(0, 1.3f, 100, 400); // x = factor, y = ior, z = min thickness, w = max thickness

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

    @property AlphaMode alphaMode() const
    {
        return cast(AlphaMode) params.z;
    }

    @property void alphaMode(AlphaMode value)
    {
        params.z = cast(int) value;
    }

    @property float alphaCutoff() const
    {
        return alphaParams.x;
    }

    @property void alphaCutoff(float value)
    {
        alphaParams.x = value;
    }

    @property float metallic() const
    {
        return metallicRoughness.x;
    }

    @property void metallic(float value)
    {
        metallicRoughness.x = value;
    }

    @property float roughness() const
    {
        return metallicRoughness.y;
    }

    @property void roughness(float value)
    {
        metallicRoughness.y = value;
    }

    @property float normalScale() const
    {
        return metallicRoughness.z;
    }

    @property void normalScale(float value)
    {
        metallicRoughness.z = value;
    }

    @property float occlusionStrength() const
    {
        return metallicRoughness.w;
    }

    @property void occlusionStrength(float value)
    {
        metallicRoughness.w = value;
    }
}

static assert(Material.sizeof == 176);

struct MaterialBlock
{
    Material material;
}

/// Runtime material edits; release builds enable them with MaterialOverride
version(MaterialOverride)
    enum runtimeMaterialOverride = true;
else
{
    debug enum runtimeMaterialOverride = true;
    else enum runtimeMaterialOverride = false;
}

/// Material uniforms of all meshes, one slot per mesh
final class MaterialBuffer
{
    static if(runtimeMaterialOverride)
        alias Chunk = MemoryBufferMappedToCPU;
    else
        alias Chunk = TransferBuffer;

    private LogicalDevice device;
    private Chunk[] chunks;
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
                chunks ~= device.create!Chunk(
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

        static if(runtimeMaterialOverride)
            auto buffer = chunk.buf;
        else
            auto buffer = chunk.gpuBuffer;

        return VkDescriptorBufferInfo(
            buffer: buffer,
            offset: (slot % chunkCapacity) * slotSize,
            range: MaterialBlock.sizeof,
        );
    }

    void recordUpload(VkCommandBuffer commandBuffer)
    {
        static if(!runtimeMaterialOverride)
        {
            Chunk[] snapshot;

            synchronized(chunkMutex)
                snapshot = chunks;

            foreach(chunk; snapshot)
                chunk.recordUpload(commandBuffer);
        }
    }

    private Chunk chunkAt(size_t slot)
    {
        Chunk chunk;

        synchronized(chunkMutex)
            chunk = chunks[slot / chunkCapacity];

        assert(chunk !is null);

        return chunk;
    }
}
