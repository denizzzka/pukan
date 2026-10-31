module pukan.pbr.mesh;

import dlib.math;
import material_bindings;
import pukan.pbr.accessor;
import pukan.pbr.instancing: InstanceBatch, currentInstanceArena;
import pukan.material: AlphaMode, Material, MaterialBuffer, MaterialFlag, MaterialFlags, MaterialMode;
import pukan.mesh: Mesh, VertexStream, fallbackVertexSize, mirrors;
import pukan.misc: Boxf, expandAABB;
import pukan.vulkan;
import pukan.vulkan.bindings;

/// Vertex input binding of the per-instance transform matrix
enum staticInstanceBinding = 5;

struct IndicesDescr
{
    BufAccess accessor;
    VkIndexType indexType;

    this(BufAccess acc, VkIndexType t)
    {
        assert(acc.stride == 0 || acc.stride == 2 || acc.stride == 4);
        assert(t == VK_INDEX_TYPE_UINT16 || t == VK_INDEX_TYPE_UINT32);

        accessor = acc;
        indexType = t;
    }
}

/// Vertex streams uploaded to GPU
package(pukan) struct MeshStreams
{
    IndicesDescr indices;
    BufAccess vertices;
    BufAccess texCoords;

    // Skin support
    BufAccess joints;
    BufAccess weights;

    BufAccess normals;
    BufAccess tangents;
    BufAccess colors;

    Boxf aabb; /// Bounds; NaN when the format omits them
}

/// CPU-side geometry for loaders that decode into arrays first
struct MeshGeometry
{
    Vector3f[] positions;
    Vector3f[] normals;
    Vector4f[] tangents;
    Vector2f[] texCoords;
    uint[] colors; /// Packed RGBA8
    Vector4us[] joints;
    Vector4f[] weights;
    uint[] indices;

    Boxf aabb;
}

alias Vector4us = Vector!(ushort, 4);

/// Sets the front face of every mesh below a node, from the accumulated transform.
/// `counterClockwise` is the winding the source stores its triangles with; nothing
/// else changes: no vertices, indices, normals or camera are touched.
void applyWinding(N, Child)(N node, Matrix4x4f trans, bool counterClockwise, scope Matrix4x4f delegate(N) localOf)
{
    trans *= localOf(node);

    const mirrored = trans.mirrors;

    foreach(mesh; node.meshes)
        mesh.applyFrontFace(mirrored, counterClockwise);

    foreach(child; node.children)
        applyWinding!(N, Child)(cast(N) child, trans, counterClockwise, localOf);
}

/// Vertex and index buffers shared by every instance of one mesh
final class PbrGeometry
{
    package(pukan) MeshStreams vert;
    package(pukan) bool hasSkin;
    uint vertexCount;
    VkBuffer indexBuffer;
    VkDeviceSize indexOffset;
    VkIndexType indexType;
    uint indexCount;

    private VkBuffer fallbackVertex;
    private VkBuffer[] buffers;
    private VkDeviceSize[] offsets;
    private VkDeviceSize[] sizes;
    private VkDeviceSize[] strides;

    package(pukan) this(MeshStreams vert, bool hasSkin, VkBuffer fallbackVertex)
    {
        this.vert = vert;
        this.hasSkin = hasSkin;
        this.fallbackVertex = fallbackVertex;

        assert(vert.vertices.viewIdx >= 0);
    }

    /// Resolves the accessors to GPU buffers once, before any instance draws
    package(pukan) void build(ref BufferPieceOnGPU[] gpuBuffs)
    {
        VertexStream stream(BufAccess accessor)
        {
            assert(accessor.viewIdx >= 0);

            auto gpuBuf = gpuBuffs[accessor.viewIdx];
            assert(gpuBuf !is null);

            return VertexStream(
                buffer: gpuBuf.buffer.gpuBuffer,
                offset: accessor.offset,
                size: gpuBuf.buffer.cpuBuf.length - accessor.offset,
                stride: accessor.stride,
            );
        }

        VertexStream constantVertex()
        {
            // A zero stride reads one element for every vertex
            return VertexStream(
                buffer: fallbackVertex,
                offset: 0,
                size: fallbackVertexSize,
                stride: 0,
            );
        }

        VertexStream[] streams = [
            stream(vert.vertices),
            vert.texCoords.viewIdx >= 0 ? stream(vert.texCoords) : constantVertex(),
        ];

        if(hasSkin)
        {
            streams ~= stream(vert.joints);
            streams ~= stream(vert.weights);
        }

        streams ~= vert.normals.viewIdx >= 0 ? stream(vert.normals) : constantVertex();
        streams ~= vert.tangents.viewIdx >= 0 ? stream(vert.tangents) : constantVertex();
        streams ~= vert.colors.viewIdx >= 0 ? stream(vert.colors) : constantVertex();

        setStreams(streams);
        vertexCount = vert.vertices.count;

        if(vert.indices.accessor.count)
        {
            auto indicesBuffer = gpuBuffs[vert.indices.accessor.viewIdx];
            assert(indicesBuffer !is null);

            indexBuffer = indicesBuffer.buffer.gpuBuffer;
            indexOffset = vert.indices.accessor.offset;
            indexType = vert.indices.indexType;
            indexCount = vert.indices.accessor.count;
        }
    }

    private void setStreams(VertexStream[] streams)
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

    package(pukan) void drawGeometry(
        VkCommandBuffer buf,
        GraphicsPipelineCfg pipeline,
        Matrix4x4f trans,
        VkFrontFace frontFace,
        VkDescriptorSet descriptorSet,
    )
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

        if(descriptorSet)
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
    }

    package(pukan) void drawInstanced(
        VkCommandBuffer buf,
        GraphicsPipelineCfg pipeline,
        InstanceBatch batch,
        VkFrontFace frontFace,
        VkDescriptorSet descriptorSet,
    )
    {
        assert(buffers.length == staticInstanceBinding);

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

        VkDeviceSize instanceOffset;
        VkDeviceSize instanceSize = batch.size;
        VkDeviceSize instanceStride = Matrix4x4f.sizeof;
        vkCmdBindVertexBuffers2(
            buf,
            staticInstanceBinding,
            1,
            &batch.buffer,
            &instanceOffset,
            &instanceSize,
            &instanceStride,
        );

        if(indexCount)
            vkCmdBindIndexBuffer(buf, indexBuffer, indexOffset, indexType);

        if(descriptorSet)
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
            vkCmdDrawIndexed(buf, indexCount, batch.count, 0, 0, batch.firstInstance);
        else
            vkCmdDraw(buf, vertexCount, batch.count, 0, batch.firstInstance);
    }

    package(pukan) auto calcAABB(in BufferPieceOnGPU[] gpuBuffs, ref Boxf box) const
    {
        import std.math: isNaN;

        if(!vert.aabb.min.x.isNaN)
        {
            debug assert(isSameAabb(vert.aabb, scannedAabb(gpuBuffs)),
                "mesh bounds differ from the vertex data");

            mergeAabb(box, vert.aabb);
            return;
        }

        mergeAabb(box, scannedAabb(gpuBuffs));
    }

    private Boxf scannedAabb(in BufferPieceOnGPU[] gpuBuffs) const
    {
        auto range = AccessRange!(Vector3f, false)(gpuBuffs[vert.vertices.viewIdx].buffer.cpuBuf, vert.vertices);

        Boxf box;
        box.min = range.front;
        box.max = box.min;

        range.popFront;

        foreach(e; range)
            expandAABB(box, e);

        return box;
    }

    private static void mergeAabb(ref Boxf box, in Boxf other)
    {
        import std.math: isNaN;

        if(box.min.x.isNaN)
        {
            box.min = other.min;
            box.max = other.max;
            return;
        }

        expandAABB(box, other.min);
        expandAABB(box, other.max);
    }

    private static bool isSameAabb(in Boxf a, in Boxf b)
    {
        import std.math: isClose;

        enum tolerance = 1e-4f;

        return
            isClose(a.min.x, b.min.x, tolerance, tolerance) &&
            isClose(a.min.y, b.min.y, tolerance, tolerance) &&
            isClose(a.min.z, b.min.z, tolerance, tolerance) &&
            isClose(a.max.x, b.max.x, tolerance, tolerance) &&
            isClose(a.max.y, b.max.y, tolerance, tolerance) &&
            isClose(a.max.z, b.max.z, tolerance, tolerance);
    }

}

final class PbrMesh : Mesh
{
    package(pukan) PbrGeometry geometry;
    package(pukan) AlphaMode alphaMode;
    package(pukan) bool doubleSided;
    package(pukan) bool hasSkin;
    bool castShadow = true;
    bool shadowsOnly;

    private VkWriteDescriptorSet jointsUboWriteDescr;
    private VkDescriptorBufferInfo jointsUboInfo;
    private VkDescriptorImageInfo[MATERIAL_GODOT_ROUGHNESS + 1] materialTextures;

    package(pukan) this(
        string name,
        PbrGeometry geometry,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        VkDescriptorImageInfo fakeTexture,
        ref VkDescriptorBufferInfo jointsUboInfo,
    )
    {
        super(materialBuffer);

        this.name = name;
        this.descriptorSet = allocator.allocate();
        this.geometry = geometry;
        this.hasSkin = geometry.hasSkin;
        materialTextures[] = fakeTexture;

        material = Material(Vector3f(1, 1, 1), MaterialMode.pbr);
        writeMaterial();

        // The write descriptor keeps a pointer to this copy, so it lives here
        this.jointsUboInfo = jointsUboInfo;
        jointsUboWriteDescr = bufferWriteDescriptor(descriptorSet, MATERIAL_JOINTS, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, this.jointsUboInfo);
    }

    package(pukan) this(
        string name,
        MeshStreams vert,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        VkDescriptorImageInfo fakeTexture,
        bool hasSkin,
        VkBuffer fallbackVertex,
        ref VkDescriptorBufferInfo jointsUboInfo,
    )
    {
        this(name, new PbrGeometry(vert, hasSkin, fallbackVertex), allocator, materialBuffer,
            fakeTexture, jointsUboInfo);
    }

    package(pukan) auto calcAABB(in BufferPieceOnGPU[] gpuBuffs, ref Boxf box) const
    {
        geometry.calcAABB(gpuBuffs, box);
    }

    /// Mesh-space bounds; NaN when the source did not provide them
    @property Boxf localAABB() const
    {
        return geometry.vert.aabb;
    }

    override void draw(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f trans, VkDescriptorSet frameSet)
    {
        if(hasSkin)
        {
            super.draw(buf, pipeline, trans, frameSet);
            return;
        }

        Matrix4x4f[1] instances = trans;
        drawBatch(buf, pipeline, instances[], frameSet);
    }

    /// Draws static instances that share this mesh in one call
    package(pukan) void drawBatch(
        VkCommandBuffer buf,
        GraphicsPipelineCfg pipeline,
        const Matrix4x4f[] transforms,
        VkDescriptorSet frameSet,
    )
    in(transforms.length > 0)
    {
        assert(!hasSkin);
        assert(currentInstanceArena !is null, "static draw outside Scene recording");

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

        auto batch = currentInstanceArena.append(transforms);

        geometry.drawInstanced(buf, pipeline, batch, frontFace, descriptorSet);
    }

    package(pukan) void bindTexture(size_t binding, MaterialFlag flag, VkDescriptorImageInfo image)
    {
        assert(binding < materialTextures.length);
        materialTextures[binding] = image;
        material.flags = material.flags | MaterialFlags(flag);
    }

    package(pukan) void commitMaterial()
    {
        writeMaterial();
    }

    void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
    {
        auto uboInfo = materialInfo();

        VkWriteDescriptorSet[] descriptorWrites = [
            jointsUboWriteDescr,
            bufferWriteDescriptor(descriptorSet, MATERIAL_UNIFORM, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, uboInfo),
            imageWriteDescriptor(descriptorSet, MATERIAL_BASE_COLOR, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_BASE_COLOR]),
            imageWriteDescriptor(descriptorSet, MATERIAL_METALLIC_ROUGHNESS, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_METALLIC_ROUGHNESS]),
            imageWriteDescriptor(descriptorSet, MATERIAL_NORMAL, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_NORMAL]),
            imageWriteDescriptor(descriptorSet, MATERIAL_OCCLUSION, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_OCCLUSION]),
            imageWriteDescriptor(descriptorSet, MATERIAL_EMISSIVE, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_EMISSIVE]),
            imageWriteDescriptor(descriptorSet, MATERIAL_SPECULAR, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_SPECULAR]),
            imageWriteDescriptor(descriptorSet, MATERIAL_SPECULAR_COLOR, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_SPECULAR_COLOR]),
            imageWriteDescriptor(descriptorSet, MATERIAL_CLEARCOAT, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_CLEARCOAT]),
            imageWriteDescriptor(descriptorSet, MATERIAL_CLEARCOAT_ROUGHNESS, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_CLEARCOAT_ROUGHNESS]),
            imageWriteDescriptor(descriptorSet, MATERIAL_CLEARCOAT_NORMAL, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_CLEARCOAT_NORMAL]),
            imageWriteDescriptor(descriptorSet, MATERIAL_SHEEN_COLOR, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_SHEEN_COLOR]),
            imageWriteDescriptor(descriptorSet, MATERIAL_SHEEN_ROUGHNESS, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_SHEEN_ROUGHNESS]),
            imageWriteDescriptor(descriptorSet, MATERIAL_ANISOTROPY, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_ANISOTROPY]),
            imageWriteDescriptor(descriptorSet, MATERIAL_IRIDESCENCE, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_IRIDESCENCE]),
            imageWriteDescriptor(descriptorSet, MATERIAL_IRIDESCENCE_THICKNESS, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_IRIDESCENCE_THICKNESS]),
            imageWriteDescriptor(descriptorSet, MATERIAL_TRANSMISSION, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_TRANSMISSION]),
            imageWriteDescriptor(descriptorSet, MATERIAL_VOLUME_THICKNESS, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_VOLUME_THICKNESS]),
            imageWriteDescriptor(descriptorSet, MATERIAL_GODOT_METALLIC, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_GODOT_METALLIC]),
            imageWriteDescriptor(descriptorSet, MATERIAL_GODOT_ROUGHNESS, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[MATERIAL_GODOT_ROUGHNESS]),
        ];

        device.updateDescriptorSets(descriptorWrites);
    }

    //TODO: remove?
    package(pukan) void refreshBuffers(VkCommandBuffer buf)
    {
    }

    package(pukan) void buildGeometry(ref BufferPieceOnGPU[] gpuBuffs)
    {
        geometry.build(gpuBuffs);
    }

    override void drawGeometry(VkCommandBuffer buf, GraphicsPipelineCfg pipeline, Matrix4x4f trans)
    {
        geometry.drawGeometry(buf, pipeline, trans, frontFace, descriptorSet);
    }
}

