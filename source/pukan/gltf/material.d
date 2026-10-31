module pukan.gltf.material;

import dlib.math: Vector3f, Vector4f;
import material_bindings;
import pukan.gltf.loader: GltfLoadOptions;
import pukan.material: AlphaMode, Material, MaterialFlag, MaterialFlags, MaterialMode;
import pukan.pbr.mesh: PbrMesh;
import pukan.vulkan.bindings;
import std.exception: enforce;
import vibe.data.json: Json, deserializeJson;

package(pukan) void applyGltfMaterial(
    PbrMesh mesh,
    in Json json,
    VkDescriptorImageInfo[] images,
    bool hasTexCoords,
    bool hasNormals,
    bool hasTangents,
    bool hasVertexColors,
    GltfLoadOptions options,
)
{
    mesh.material = Material(Vector3f(1, 1, 1), MaterialMode.pbr);
    mesh.alphaMode = AlphaMode.opaque;
    mesh.doubleSided = false;

    void bindTexture(in Json texture, size_t binding, MaterialFlag flag)
    {
        if(!hasTexCoords)
            return;

        const index = texture["index"].get!size_t;
        enforce(index < images.length, "glTF material references a missing texture");

        mesh.bindTexture(binding, flag, images[index]);
    }

    if(options.modeOverride >= 0)
        mesh.material.mode = cast(MaterialMode) options.modeOverride;

    if(json.type == Json.Type.object)
    {
        if(options.extensions)
            if(auto extensions = "extensions" in json)
                if("KHR_materials_unlit" in *extensions)
                    if(options.modeOverride < 0)
                        mesh.material.mode = MaterialMode.unlit;

        // Unlit keeps base color and alpha only
        const bool lit = mesh.material.mode != MaterialMode.unlit;

        if(auto pbr = "pbrMetallicRoughness" in json)
        {
            if(auto factor = "baseColorFactor" in *pbr)
            {
                const c = (*factor).deserializeJson!(float[4]);
                mesh.material.baseColorFactor = Vector4f(c[0], c[1], c[2], c[3]);
            }

            if(auto factor = "metallicFactor" in *pbr)
                mesh.material.metallic = readFloat(*factor);

            if(auto factor = "roughnessFactor" in *pbr)
                mesh.material.roughness = readFloat(*factor);

            if(auto texture = "baseColorTexture" in *pbr)
                bindTexture(*texture, MATERIAL_BASE_COLOR, MaterialFlag.baseColorTexture);

            if(lit)
                if(auto texture = "metallicRoughnessTexture" in *pbr)
                    bindTexture(*texture, MATERIAL_METALLIC_ROUGHNESS, MaterialFlag.metallicRoughnessTexture);
        }

        if(lit)
        {
            if(auto texture = "normalTexture" in json)
            {
                bindTexture(*texture, MATERIAL_NORMAL, MaterialFlag.normalTexture);

                if(auto scale = "scale" in *texture)
                    mesh.material.normalScale = readFloat(*scale);
            }

            if(auto texture = "occlusionTexture" in json)
            {
                bindTexture(*texture, MATERIAL_OCCLUSION, MaterialFlag.occlusionTexture);

                if(auto strength = "strength" in *texture)
                    mesh.material.occlusionStrength = readFloat(*strength);
            }

            if(auto texture = "emissiveTexture" in json)
                bindTexture(*texture, MATERIAL_EMISSIVE, MaterialFlag.emissiveTexture);

            if(auto factor = "emissiveFactor" in json)
            {
                const e = (*factor).deserializeJson!(float[3]);
                mesh.material.emissiveFactor = Vector4f(e[0], e[1], e[2], 0);
            }

            const extensions = options.extensions ? "extensions" in json : null;

            if(extensions !is null)
            {
                if(auto emissive = "KHR_materials_emissive_strength" in *extensions)
                    if(auto strength = "emissiveStrength" in *emissive)
                        mesh.material.emissiveFactor = mesh.material.emissiveFactor * readFloat(*strength);

                if(auto ior = "KHR_materials_ior" in *extensions)
                    if(auto value = "ior" in *ior)
                        mesh.material.iorParams.x = readFloat(*value);

                if(auto specular = "KHR_materials_specular" in *extensions)
                {
                    if(auto value = "specularFactor" in *specular)
                        mesh.material.specular.w = readFloat(*value);

                    if(auto value = "specularColorFactor" in *specular)
                    {
                        const c = (*value).deserializeJson!(float[3]);
                        mesh.material.specular.x = c[0];
                        mesh.material.specular.y = c[1];
                        mesh.material.specular.z = c[2];
                    }

                    if(auto texture = "specularTexture" in *specular)
                        bindTexture(*texture, MATERIAL_SPECULAR, MaterialFlag.specularTexture);

                    if(auto texture = "specularColorTexture" in *specular)
                        bindTexture(*texture, MATERIAL_SPECULAR_COLOR, MaterialFlag.specularColorTexture);
                }

                if(auto clearcoat = "KHR_materials_clearcoat" in *extensions)
                {
                    if(auto value = "clearcoatFactor" in *clearcoat)
                        mesh.material.clearcoat.x = readFloat(*value);

                    if(auto value = "clearcoatRoughnessFactor" in *clearcoat)
                        mesh.material.clearcoat.y = readFloat(*value);

                    if(auto texture = "clearcoatTexture" in *clearcoat)
                        bindTexture(*texture, MATERIAL_CLEARCOAT, MaterialFlag.clearcoatTexture);

                    if(auto texture = "clearcoatRoughnessTexture" in *clearcoat)
                        bindTexture(*texture, MATERIAL_CLEARCOAT_ROUGHNESS, MaterialFlag.clearcoatRoughnessTexture);

                    if(auto texture = "clearcoatNormalTexture" in *clearcoat)
                    {
                        bindTexture(*texture, MATERIAL_CLEARCOAT_NORMAL, MaterialFlag.clearcoatNormalTexture);

                        if(auto scale = "scale" in *texture)
                            mesh.material.clearcoat.z = readFloat(*scale);
                    }
                }

                if(auto sheen = "KHR_materials_sheen" in *extensions)
                {
                    if(auto value = "sheenColorFactor" in *sheen)
                    {
                        const c = (*value).deserializeJson!(float[3]);
                        mesh.material.sheen.x = c[0];
                        mesh.material.sheen.y = c[1];
                        mesh.material.sheen.z = c[2];
                    }

                    if(auto value = "sheenRoughnessFactor" in *sheen)
                        mesh.material.sheen.w = readFloat(*value);

                    if(auto texture = "sheenColorTexture" in *sheen)
                        bindTexture(*texture, MATERIAL_SHEEN_COLOR, MaterialFlag.sheenColorTexture);

                    if(auto texture = "sheenRoughnessTexture" in *sheen)
                        bindTexture(*texture, MATERIAL_SHEEN_ROUGHNESS, MaterialFlag.sheenRoughnessTexture);
                }

                if(auto anisotropy = "KHR_materials_anisotropy" in *extensions)
                {
                    if(auto value = "anisotropyStrength" in *anisotropy)
                        mesh.material.anisotropy.x = readFloat(*value);

                    if(auto value = "anisotropyRotation" in *anisotropy)
                        mesh.material.anisotropy.y = readFloat(*value);

                    if(auto texture = "anisotropyTexture" in *anisotropy)
                        bindTexture(*texture, MATERIAL_ANISOTROPY, MaterialFlag.anisotropyTexture);
                }

                if(auto iridescence = "KHR_materials_iridescence" in *extensions)
                {
                    if(auto value = "iridescenceFactor" in *iridescence)
                        mesh.material.iridescence.x = readFloat(*value);

                    if(auto value = "iridescenceIor" in *iridescence)
                        mesh.material.iridescence.y = readFloat(*value);

                    if(auto value = "iridescenceThicknessMinimum" in *iridescence)
                        mesh.material.iridescence.z = readFloat(*value);

                    if(auto value = "iridescenceThicknessMaximum" in *iridescence)
                        mesh.material.iridescence.w = readFloat(*value);

                    if(auto texture = "iridescenceTexture" in *iridescence)
                        bindTexture(*texture, MATERIAL_IRIDESCENCE, MaterialFlag.iridescenceTexture);

                    if(auto texture = "iridescenceThicknessTexture" in *iridescence)
                        bindTexture(*texture, MATERIAL_IRIDESCENCE_THICKNESS, MaterialFlag.iridescenceThicknessTexture);
                }

                if(auto transmission = "KHR_materials_transmission" in *extensions)
                {
                    if(auto value = "transmissionFactor" in *transmission)
                        mesh.material.transmission.x = readFloat(*value);

                    if(auto texture = "transmissionTexture" in *transmission)
                        bindTexture(*texture, MATERIAL_TRANSMISSION, MaterialFlag.transmissionTexture);
                }

                if(auto volume = "KHR_materials_volume" in *extensions)
                {
                    if(auto value = "thicknessFactor" in *volume)
                        mesh.material.volume.x = readFloat(*value);

                    if(auto value = "attenuationDistance" in *volume)
                        mesh.material.volume.y = readFloat(*value);

                    if(auto value = "attenuationColor" in *volume)
                    {
                        const c = (*value).deserializeJson!(float[3]);
                        mesh.material.attenuationColor.x = c[0];
                        mesh.material.attenuationColor.y = c[1];
                        mesh.material.attenuationColor.z = c[2];
                    }

                    if(auto texture = "thicknessTexture" in *volume)
                        bindTexture(*texture, MATERIAL_VOLUME_THICKNESS, MaterialFlag.volumeThicknessTexture);
                }

                if(auto dispersion = "KHR_materials_dispersion" in *extensions)
                    if(auto value = "dispersion" in *dispersion)
                        mesh.material.volume.z = readFloat(*value);
            }
        }

        if(auto mode = "alphaMode" in json)
        {
            const value = (*mode).get!string;
            if(value == "MASK")
                mesh.alphaMode = AlphaMode.mask;
            else if(value == "BLEND")
                mesh.alphaMode = AlphaMode.blend;
        }

        if(auto cutoff = "alphaCutoff" in json)
            mesh.material.alphaCutoff = readFloat(*cutoff);

        if(auto value = "doubleSided" in json)
            mesh.doubleSided = (*value).get!bool;
    }

    mesh.material.alphaMode = mesh.alphaMode;

    if(hasVertexColors)
        mesh.material.flags = mesh.material.flags | MaterialFlag.vertexColor;

    if(hasTangents && mesh.material.flags.normalTexture)
        mesh.material.flags = mesh.material.flags | MaterialFlag.vertexTangent;

    if(!hasNormals || mesh.material.mode == MaterialMode.unlit)
        mesh.material.flags = mesh.material.flags | MaterialFlag.derivedNormals;

    mesh.commitMaterial();
}

private static float readFloat(in Json value)
{
    if(value.type == Json.Type.int_)
        return cast(float) value.get!long;

    return cast(float) value.get!double;
}
