module pukan.gltf.mesh;

import dlib.math;
import pukan.gltf.accessor;
public import pukan.gltf.loader: ComponentType;
import pukan.material: AlphaMode, Material, MaterialBuffer, MaterialFlag, MaterialFlags, MaterialMode;
import pukan.mesh: Mesh, VertexStream, fallbackVertexSize;
import pukan.misc: Boxf, expandAABB;
import pukan.vulkan;
import pukan.vulkan.bindings;
import std.exception: enforce;
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
        BufAccess[6] allBuffers;
        struct
        {
            BufAccess vertices;
            BufAccess texCoords;

            // Skin support
            BufAccess joints;
            BufAccess weights;

            BufAccess normals;
            BufAccess tangents;
        }
    }

    Boxf aabb; /// Accessor bounds; NaN when the file omits them
}

final class GltfMesh : Mesh
{
    private enum baseColorSlot = 0;
    private enum metallicRoughnessSlot = 1;
    private enum normalSlot = 2;
    private enum occlusionSlot = 3;
    private enum emissiveSlot = 4;
    private enum specularSlot = 5;
    private enum specularColorSlot = 6;

    package UploadedVertices vert;
    package AlphaMode alphaMode;
    package bool doubleSided;
    package bool hasSkin;

    private VkWriteDescriptorSet jointsUboWriteDescr;
    private VkDescriptorImageInfo[7] materialTextures;
    private VkBuffer fallbackVertex;

    package this(
        string name,
        UploadedVertices vert,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        VkDescriptorImageInfo fakeTexture,
        bool hasSkin,
        VkBuffer fallbackVertex,
        ref VkDescriptorBufferInfo jointsUboInfo,
    )
    {
        super(materialBuffer);

        this.name = name;
        this.descriptorSet = allocator.allocate();
        this.vert = vert;
        this.hasSkin = hasSkin;
        this.fallbackVertex = fallbackVertex;
        materialTextures[] = fakeTexture;

        assert(vert.vertices.viewIdx >= 0);

        material = Material(Vector3f(1, 1, 1), MaterialMode.pbr);
        writeMaterial();

        jointsUboWriteDescr = bufferWriteDescriptor(descriptorSet, 2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, jointsUboInfo);
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

    package void applyMaterial(
        in Json json,
        VkDescriptorImageInfo[] images,
        bool hasTexCoords,
        bool hasNormals,
        bool hasTangents,
    )
    {
        material = Material(Vector3f(1, 1, 1), MaterialMode.pbr);
        alphaMode = AlphaMode.opaque;
        doubleSided = false;

        if(json.type == Json.Type.object)
        {
            if(auto extensions = "extensions" in json)
                if("KHR_materials_unlit" in *extensions)
                    material.mode = MaterialMode.unlit;

            // Unlit keeps base color and alpha only
            const bool lit = material.mode != MaterialMode.unlit;

            if(auto pbr = "pbrMetallicRoughness" in json)
            {
                if(auto factor = "baseColorFactor" in *pbr)
                {
                    const c = (*factor).deserializeJson!(float[4]);
                    material.baseColorFactor = Vector4f(c[0], c[1], c[2], c[3]);
                }

                if(auto factor = "metallicFactor" in *pbr)
                    material.metallic = readFloat(*factor);

                if(auto factor = "roughnessFactor" in *pbr)
                    material.roughness = readFloat(*factor);

                if(auto texture = "baseColorTexture" in *pbr)
                    bindTexture(*texture, baseColorSlot, MaterialFlag.baseColorTexture, images, hasTexCoords);

                if(lit)
                    if(auto texture = "metallicRoughnessTexture" in *pbr)
                        bindTexture(*texture, metallicRoughnessSlot, MaterialFlag.metallicRoughnessTexture, images, hasTexCoords);
            }

            if(lit)
            {
                if(auto texture = "normalTexture" in json)
                {
                    bindTexture(*texture, normalSlot, MaterialFlag.normalTexture, images, hasTexCoords);

                    if(auto scale = "scale" in *texture)
                        material.normalScale = readFloat(*scale);
                }

                if(auto texture = "occlusionTexture" in json)
                {
                    bindTexture(*texture, occlusionSlot, MaterialFlag.occlusionTexture, images, hasTexCoords);

                    if(auto strength = "strength" in *texture)
                        material.occlusionStrength = readFloat(*strength);
                }

                if(auto texture = "emissiveTexture" in json)
                    bindTexture(*texture, emissiveSlot, MaterialFlag.emissiveTexture, images, hasTexCoords);

                if(auto factor = "emissiveFactor" in json)
                {
                    const e = (*factor).deserializeJson!(float[3]);
                    material.emissiveFactor = Vector4f(e[0], e[1], e[2], 0);
                }

                if(auto extensions = "extensions" in json)
                {
                    if(auto emissive = "KHR_materials_emissive_strength" in *extensions)
                        if(auto strength = "emissiveStrength" in *emissive)
                            material.emissiveFactor = material.emissiveFactor * readFloat(*strength);

                    if(auto ior = "KHR_materials_ior" in *extensions)
                        if(auto value = "ior" in *ior)
                            material.iorParams.x = readFloat(*value);

                    if(auto specular = "KHR_materials_specular" in *extensions)
                    {
                        if(auto value = "specularFactor" in *specular)
                            material.specular.w = readFloat(*value);

                        if(auto value = "specularColorFactor" in *specular)
                        {
                            const c = (*value).deserializeJson!(float[3]);
                            material.specular.x = c[0];
                            material.specular.y = c[1];
                            material.specular.z = c[2];
                        }

                        if(auto texture = "specularTexture" in *specular)
                            bindTexture(*texture, specularSlot, MaterialFlag.specularTexture, images, hasTexCoords);

                        if(auto texture = "specularColorTexture" in *specular)
                            bindTexture(*texture, specularColorSlot, MaterialFlag.specularColorTexture, images, hasTexCoords);
                    }
                }
            }

            if(auto mode = "alphaMode" in json)
            {
                const value = (*mode).get!string;
                if(value == "MASK")
                    alphaMode = AlphaMode.mask;
                else if(value == "BLEND")
                    alphaMode = AlphaMode.blend;
            }

            if(auto cutoff = "alphaCutoff" in json)
                material.alphaCutoff = readFloat(*cutoff);

            if(auto value = "doubleSided" in json)
                doubleSided = (*value).get!bool;
        }

        material.alphaMode = alphaMode;

        if(hasTangents && material.flags.normalTexture)
            material.flags = material.flags | MaterialFlag.vertexTangent;

        if(!hasNormals || material.mode == MaterialMode.unlit)
            material.flags = material.flags | MaterialFlag.derivedNormals;

        writeMaterial();
    }

    private static float readFloat(in Json value)
    {
        if(value.type == Json.Type.int_)
            return cast(float) value.get!long;

        return cast(float) value.get!double;
    }

    private void bindTexture(
        in Json texture,
        size_t slot,
        MaterialFlag flag,
        VkDescriptorImageInfo[] images,
        bool hasTexCoords,
    )
    {
        if(!hasTexCoords)
            return;

        const index = texture["index"].get!size_t;
        enforce(index < images.length, "glTF material references a missing texture");

        materialTextures[slot] = images[index];
        material.flags = material.flags | MaterialFlags(flag);
    }

    void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
    {
        auto uboInfo = materialInfo();

        VkWriteDescriptorSet[] descriptorWrites = [
            jointsUboWriteDescr,
            bufferWriteDescriptor(descriptorSet, 0, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, uboInfo),
            imageWriteDescriptor(descriptorSet, 1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[baseColorSlot]),
            imageWriteDescriptor(descriptorSet, 3, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[metallicRoughnessSlot]),
            imageWriteDescriptor(descriptorSet, 4, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[normalSlot]),
            imageWriteDescriptor(descriptorSet, 5, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[occlusionSlot]),
            imageWriteDescriptor(descriptorSet, 6, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[emissiveSlot]),
            imageWriteDescriptor(descriptorSet, 7, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[specularSlot]),
            imageWriteDescriptor(descriptorSet, 8, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, materialTextures[specularColorSlot]),
        ];

        device.updateDescriptorSets(descriptorWrites);
    }

    //TODO: remove?
    package void refreshBuffers(VkCommandBuffer buf)
    {
    }

    /// Binds the streams the material actually reads, zeroed fallbacks otherwise.
    package void buildGeometry(ref BufferPieceOnGPU[] gpuBuffs)
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

        const bool needsNormals = material.mode != MaterialMode.unlit;
        const bool needsTangents = needsNormals && material.flags.vertexTangent;

        VertexStream[] streams = [
            stream(vert.vertices),
            vert.texCoords.viewIdx >= 0 ? stream(vert.texCoords) : constantVertex(),
        ];

        if(hasSkin)
        {
            streams ~= stream(vert.joints);
            streams ~= stream(vert.weights);
        }

        streams ~= needsNormals && vert.normals.viewIdx >= 0 ? stream(vert.normals) : constantVertex();
        streams ~= needsTangents ? stream(vert.tangents) : constantVertex();

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
