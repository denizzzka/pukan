module pukan.graphics.g3d.mesh;

import dlib.math: Matrix4x4f, Vector4f;
import pukan.graphics.g3d.material: Material, MaterialBuffer;
import pukan.graphics.g3d.stats: countDraw, triangleCount;
import pukan.vulkan.bindings;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: MemoryBufferMappedToCPU;
import pukan.vulkan.pipelines: GraphicsPipelineCfg;
import pukan.vulkan.textures: Texture, createFakeTexture1x1;

/// One vertex buffer bound to a vertex input binding
struct VertexStream
{
    VkBuffer buffer;
    VkDeviceSize offset;
    VkDeviceSize size;
    uint stride;
}

/// Bytes a fallback vertex provides, wide enough for the largest attribute format
enum fallbackVertexSize = Vector4f.sizeof;

/// Resources shared by static and skinned meshes
final class MeshResources
{
    MaterialBuffer materials;
    MemoryBufferMappedToCPU identityJoints;
    VkDescriptorBufferInfo identityJointsInfo;
    Texture fakeTexture;
    /// Zeroed source for vertex attributes a mesh does not provide
    MemoryBufferMappedToCPU fallbackVertex;

    this(LogicalDevice device, size_t materialCapacity = 16)
    {
        materials = new MaterialBuffer(device, materialCapacity);

        fallbackVertex = device.create!MemoryBufferMappedToCPU(
            fallbackVertexSize,
            VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        (cast(ubyte[]) fallbackVertex.cpuBuf)[] = 0;

        identityJoints = device.create!MemoryBufferMappedToCPU(
            Matrix4x4f.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );
        (cast(Matrix4x4f[]) identityJoints.cpuBuf)[0] = Matrix4x4f.identity;
        identityJointsInfo = VkDescriptorBufferInfo(
            buffer: identityJoints.buf,
            offset: 0,
            range: Matrix4x4f.sizeof,
        );

        fakeTexture = createFakeTexture1x1(device);
    }

    ~this()
    {
        if(fakeTexture)
            destroy(fakeTexture);

        if(fallbackVertex)
            destroy(fallbackVertex);

        if(identityJoints)
            destroy(identityJoints);

        if(materials)
            destroy(materials);
    }
}

/// True when the transform has a negative determinant, that is, it mirrors
bool mirrors(Matrix4x4f m)
{
    return m.a11 * (m.a22 * m.a33 - m.a23 * m.a32)
        - m.a12 * (m.a21 * m.a33 - m.a23 * m.a31)
        + m.a13 * (m.a21 * m.a32 - m.a22 * m.a31) < 0;
}

/// Vulkan front face for triangles wound clockwise or counter-clockwise
/// outward, mirrored or not
VkFrontFace frontFaceFor(bool mirrored, bool counterClockwiseTriangles)
{
    return mirrored != counterClockwiseTriangles
        ? VK_FRONT_FACE_COUNTER_CLOCKWISE
        : VK_FRONT_FACE_CLOCKWISE;
}

/// Geometry and descriptor set shared by static and skinned meshes
class Mesh
{
    string name;
    VkDescriptorSet descriptorSet;
    uint vertexCount;
    Material material;

    VkBuffer indexBuffer;
    VkDeviceSize indexOffset;
    VkIndexType indexType;
    uint indexCount;

    /// Native winding of this mesh; set per draw with dynamic state
    VkFrontFace frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;

    /// Whether the transform chain that places this mesh mirrors
    bool mirrored;

    /// Godot keeps clockwise triangles and glTF counter-clockwise ones, and
    /// Vulkan's Y-down clip space adds one flip that both then need
    void applyFrontFace(bool mirrored, bool counterClockwiseTriangles)
    {
        this.mirrored = mirrored;
        frontFace = frontFaceFor(mirrored, counterClockwiseTriangles);
    }

    protected MaterialBuffer materialBuffer;
    protected size_t materialSlot;

    private VkBuffer[] buffers;
    private VkDeviceSize[] offsets;
    private VkDeviceSize[] sizes;
    private VkDeviceSize[] strides;

    this(MaterialBuffer materialBuffer)
    {
        this.materialBuffer = materialBuffer;
        writeMaterial();
    }

    /// The material reaches the GPU on the next `recordUpload`.
    void setMaterial(Material value)
    {
        material = value;
        writeMaterial();
    }

    protected void writeMaterial()
    {
        materialSlot = materialBuffer.addMaterial(material);
    }

    protected VkDescriptorBufferInfo materialInfo()
    {
        return materialBuffer.info(materialSlot);
    }

    /// Sets the vertex streams in vertex input binding order
    void setStreams(VertexStream[] streams)
    {
        buffers.length = streams.length;
        offsets.length = streams.length;
        sizes.length = streams.length;
        strides.length = streams.length;

        foreach(i, ref stream; streams)
        {
            buffers[i] = stream.buffer;
            offsets[i] = stream.offset;
            sizes[i] = stream.size;
            strides[i] = stream.stride;
        }
    }

    void draw(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f trans, VkDescriptorSet frameSet)
    {
        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);

        if(frameSet)
            vkCmdBindDescriptorSets(
                buf,
                VK_PIPELINE_BIND_POINT_GRAPHICS,
                pipeline.pipelineLayout,
                1,
                1,
                &frameSet,
                0,
                null,
            );

        drawGeometry(buf, pipeline, trans);
    }

    /// Records a depth-only draw with a pipeline that binds no material
    void drawShadow(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f trans)
    {
        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);
        drawGeometryImpl(buf, pipeline, trans, false);
    }

    /// Draws assuming the pipeline is already bound
    void drawGeometry(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f trans)
    {
        drawGeometryImpl(buf, pipeline, trans, true);
    }

    private void drawGeometryImpl(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f trans,
        bool bindMaterial)
    {
        vkCmdPushConstants(
            buf,
            pipeline.pipelineLayout,
            VK_SHADER_STAGE_VERTEX_BIT,
            0,
            cast(uint) trans.sizeof,
            cast(void*) &trans,
        );

        if(buffers.length)
            vkCmdBindVertexBuffers2(
                buf,
                0,
                cast(uint) buffers.length,
                buffers.ptr,
                offsets.ptr,
                sizes.ptr,
                strides.ptr,
            );

        if(indexCount)
            vkCmdBindIndexBuffer(buf, indexBuffer, indexOffset, indexType);

        if(bindMaterial && descriptorSet)
            vkCmdBindDescriptorSets(
                buf,
                VK_PIPELINE_BIND_POINT_GRAPHICS,
                pipeline.pipelineLayout,
                0,
                1,
                &descriptorSet,
                0,
                null,
            );

        vkCmdSetFrontFace(buf, frontFace);

        if(indexCount)
            vkCmdDrawIndexed(buf, indexCount, 1, 0, 0, 0);
        else
            vkCmdDraw(buf, vertexCount, 1, 0, 0);

        countDraw(1, triangleCount(indexCount ? indexCount : vertexCount));
    }
}

unittest
{
    import dlib.math: Vector3f, Vector4f;
    import pukan.graphics.g3d.camera: vulkanPerspectiveMatrix;

    // A counter-clockwise outward triangle in view space, as the primitives are
    // wound. The Vulkan projection flips Y, so its signed area turns negative.
    const projection = vulkanPerspectiveMatrix(60, 1, 0.1f, 100);

    Vector4f project(Vector3f p)
    {
        const clip = Vector4f(p.x, p.y, p.z, 1) * projection;
        return Vector4f(clip.x / clip.w, clip.y / clip.w, 0, 0);
    }

    const a = project(Vector3f(-1, -1, -1));
    const b = project(Vector3f(1, -1, -1));
    const c = project(Vector3f(0, 1, -1));
    const area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y);

    assert(area < 0, "the projection no longer keeps counter-clockwise outward geometry front-facing");
    assert(frontFaceFor(false, true) == VK_FRONT_FACE_COUNTER_CLOCKWISE);
}
