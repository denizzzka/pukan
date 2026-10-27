module pukan.gltf.mesh;

import dlib.math;
import pukan.gltf.accessor;
public import pukan.gltf.loader: ComponentType;
import pukan.material: MaterialBuffer, MaterialFlag, MaterialFlags, MaterialMode;
import pukan.mesh: Mesh, VertexStream;
import pukan.misc: Boxf, expandAABB;
import pukan.vulkan;
import pukan.vulkan.bindings;
import vibe.data.json: Json, deserializeJson;

struct IndicesDescr
{
    BufAccess accessor;
    VkIndexType indexType;

    this(LogicalDevice device, BufAccess acc, ComponentType t)
    {
        assert(acc.stride == 0 || acc.stride == 2 || acc.stride == 4);

        accessor = acc;

        with(ComponentType)
        switch(t)
        {
            case UNSIGNED_SHORT: indexType = VK_INDEX_TYPE_UINT16; break;
            case UNSIGNED_INT: indexType = VK_INDEX_TYPE_UINT32; break;
            default: assert(0);
        }
    }
}

/// Vertices, uploaded to GPU
package struct UploadedVertices
{
    IndicesDescr indices;
    union
    {
        BufAccess[4] allBuffers;
        struct
        {
            BufAccess vertices;
            BufAccess texCoords;

            // Skin support
            BufAccess joints;
            BufAccess weights;
        }
    }

    Boxf aabb; /// Accessor bounds; NaN when the file omits them
}

class GltfMesh : Mesh
{
    package UploadedVertices vert;

    private VkWriteDescriptorSet jointsUboWriteDescr;

    package this(
        string name,
        UploadedVertices vert,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        ref BufferPieceOnGPU[] gpuBuffs,
        ref VkDescriptorBufferInfo jointsUboInfo,
    )
    {
        super(materialBuffer);

        this.name = name;
        this.descriptorSet = allocator.allocate();
        this.vert = vert;

        assert(vert.vertices.viewIdx >= 0);

        if(vert.texCoords.viewIdx < 0)
            this.vert.texCoords = vert.vertices; // fake data to fill out texture coords buffer on non-textured objects

        material.baseColorFactor = Vector4f(0, 1, 1, 1);
        material.mode = MaterialMode.unlit;
        writeMaterial();

        jointsUboWriteDescr = bufferWriteDescriptor(descriptorSet, 2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, jointsUboInfo);

        buildGeometry(gpuBuffs);
    }

    package auto calcAABB(in BufferPieceOnGPU[] gpuBuffs, ref Boxf box) const
    {
        import std.math: isNaN;

        if(!vert.aabb.min.x.isNaN)
        {
            debug assert(isSameAabb(vert.aabb, scannedAabb(gpuBuffs)),
                "glTF accessor bounds differ from the vertex data");

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

        enum tolerance = 1e-5f;

        return
            isClose(a.min.x, b.min.x, tolerance, tolerance) &&
            isClose(a.min.y, b.min.y, tolerance, tolerance) &&
            isClose(a.min.z, b.min.z, tolerance, tolerance) &&
            isClose(a.max.x, b.max.x, tolerance, tolerance) &&
            isClose(a.max.y, b.max.y, tolerance, tolerance) &&
            isClose(a.max.z, b.max.z, tolerance, tolerance);
    }

    package void applyMaterial(Json json)
    {
        if(json.type != Json.Type.object)
            return;

        if(auto pbr = "pbrMetallicRoughness" in json)
            if(auto factor = "baseColorFactor" in *pbr)
            {
                const c = (*factor).deserializeJson!(float[4]);
                material.baseColorFactor = Vector4f(c[0], c[1], c[2], c[3]);
            }

        if(auto factor = "emissiveFactor" in json)
        {
            const e = (*factor).deserializeJson!(float[3]);
            material.emissiveFactor = Vector4f(e[0], e[1], e[2], 0);
        }

        writeMaterial();
    }

    abstract void updateDescriptorSetsAndUniformBuffers(LogicalDevice device);

    //TODO: remove?
    package void refreshBuffers(VkCommandBuffer buf)
    {
    }

    private void buildGeometry(ref BufferPieceOnGPU[] gpuBuffs)
    {
        VertexStream[] streams;

        foreach(i, accessor; vert.allBuffers)
        {
            auto acc = accessor;

            if(acc.viewIdx < 0 && i >= 2)
                acc.viewIdx = gpuBuffs.length - (4 - i);

            assert(acc.viewIdx >= 0);

            auto gpuBuf = gpuBuffs[acc.viewIdx];
            assert(gpuBuf !is null);

            streams ~= VertexStream(
                buffer: gpuBuf.buffer.gpuBuffer,
                offset: acc.offset,
                size: gpuBuf.buffer.cpuBuf.length - acc.offset,
                stride: acc.stride,
            );
        }

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
}

///
final class JustColoredMesh : GltfMesh
{
    private VkDescriptorImageInfo fakeTexture;

    package this(
        string name,
        UploadedVertices vert,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        ref BufferPieceOnGPU[] gpuBuffs,
        VkDescriptorImageInfo fakeTexture,
        ref VkDescriptorBufferInfo jointsUboInfo,
    )
    {
        this.fakeTexture = fakeTexture;

        super(name, vert, allocator, materialBuffer, gpuBuffs, jointsUboInfo);
    }

    override void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
    {
        auto uboInfo = materialInfo();

        VkWriteDescriptorSet[] descriptorWrites = [
            jointsUboWriteDescr,
            bufferWriteDescriptor(descriptorSet, 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, uboInfo),
            imageWriteDescriptor(descriptorSet, 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, fakeTexture),
        ];

        device.updateDescriptorSets(descriptorWrites);
    }
}

///
final class TexturedMesh : GltfMesh
{
    /*private*/ VkDescriptorImageInfo* textureDescrImageInfo;

    package this(
        string name,
        UploadedVertices vert,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        ref BufferPieceOnGPU[] gpuBuffs,
        ref VkDescriptorBufferInfo jointsUboInfo,
    )
    {
        super(name, vert, allocator, materialBuffer, gpuBuffs, jointsUboInfo);

        material.baseColorFactor = Vector4f(1, 1, 1, 1);
        material.flags = MaterialFlags(MaterialFlag.baseColorTexture);
        writeMaterial();
    }

    override void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
    {
        auto uboInfo = materialInfo();

        VkWriteDescriptorSet[] descriptorWrites = [
            jointsUboWriteDescr,
            bufferWriteDescriptor(descriptorSet, 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, uboInfo),
            imageWriteDescriptor(descriptorSet, 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, *textureDescrImageInfo),
        ];

        device.updateDescriptorSets(descriptorWrites);
    }
}
