module pukan.godot_scene.material;

import dlib.math: Vector3f, Vector4f, Vector4i;
import pukan.godot_scene.value;
import pukan.material: AlphaMode, Material, MaterialFlag, MaterialFlags, MaterialMode;

/// Material state read from a Godot BaseMaterial3D resource
struct GodotMaterialData
{
    Material material;
    AlphaMode alphaMode = AlphaMode.opaque;
    bool doubleSided;
    bool hasVertexColors;

    GodotObjectRef baseColorTexture;
    GodotObjectRef normalTexture;
    GodotObjectRef occlusionTexture;
    GodotObjectRef emissiveTexture;
    GodotObjectRef metallicTexture;
    GodotObjectRef roughnessTexture;

    bool hasBaseColorTexture;
    bool hasNormalTexture;
    bool hasOcclusionTexture;
    bool hasEmissiveTexture;
    bool hasMetallicTexture;
    bool hasRoughnessTexture;

    int metallicChannel;
    int roughnessChannel;
    int occlusionChannel;
    Vector4f uvTransform = Vector4f(1, 1, 0, 0);
    /// Godot's texture_filter, linear with mipmaps by default
    uint textureFilter = 3;
    bool textureRepeat = true;
    string documentPath;
}

GodotMaterialData readGodotMaterial(
    string type,
    in GodotVariant[string] properties,
    bool meshHasColors,
    string documentPath = "",
)
{
    GodotMaterialData result;
    result.documentPath = documentPath;
    result.material = Material(Vector3f(1, 1, 1), MaterialMode.pbr);

    if(auto value = "albedo_color" in properties)
    {
        const c = as!(GodotColor)(*value).toVector4();
        result.material.baseColorFactor = c;
    }

    if(auto value = "albedo_texture" in properties)
    {
        result.baseColorTexture = asObjectRef(*value, "albedo_texture");
        result.hasBaseColorTexture = true;
    }

    {
        Vector3f uvScale = Vector3f(1, 1, 1);
        Vector3f uvOffset = Vector3f(0, 0, 0);

        if(auto value = "uv1_scale" in properties)
            uvScale = as!(Vector3f)(*value, "uv1_scale");

        if(auto value = "uv1_offset" in properties)
            uvOffset = as!(Vector3f)(*value, "uv1_offset");

        result.uvTransform = Vector4f(uvScale.x, uvScale.y, uvOffset.x, uvOffset.y);
    }

    result.metallicChannel = cast(int) propertyLong(properties, "metallic_texture_channel", 0);
    result.roughnessChannel = cast(int) propertyLong(properties, "roughness_texture_channel", 0);
    result.occlusionChannel = cast(int) propertyLong(properties, "ao_texture_channel", 0);
    result.textureFilter = cast(uint) propertyLong(properties, "texture_filter", 3);

    if(auto value = "texture_repeat" in properties)
        result.textureRepeat = asBool(*value, "texture_repeat");

    if(auto value = "metallic_texture" in properties)
    {
        result.metallicTexture = asObjectRef(*value, "metallic_texture");
        result.hasMetallicTexture = true;
    }

    if(auto value = "roughness_texture" in properties)
    {
        result.roughnessTexture = asObjectRef(*value, "roughness_texture");
        result.hasRoughnessTexture = true;
    }

    if(auto value = "vertex_color_use_as_albedo" in properties)
    {
        result.hasVertexColors = meshHasColors && asBool(*value, "vertex_color_use_as_albedo");
        if(result.hasVertexColors)
            result.material.flags = result.material.flags | MaterialFlag.vertexColor;
    }

    if(auto value = "metallic" in properties)
        result.material.metallic = cast(float) asDouble(*value, "metallic");

    if(auto value = "roughness" in properties)
        result.material.roughness = cast(float) asDouble(*value, "roughness");

    if(auto value = "emission_enabled" in properties)
    {
        if(asBool(*value, "emission_enabled"))
        {
            Vector4f emission = Vector4f(0, 0, 0, 0);

            if(auto color = "emission" in properties)
                emission = as!(GodotColor)(*color).toVector4();

            float energy = 1.0f;
            if(auto multiplier = "emission_energy_multiplier" in properties)
                energy = cast(float) asDouble(*multiplier, "emission_energy_multiplier");

            if(auto texture = "emission_texture" in properties)
            {
                result.emissiveTexture = asObjectRef(*texture, "emission_texture");
                result.hasEmissiveTexture = true;
            }

            result.material.emissiveFactor = Vector4f(emission.x * energy, emission.y * energy, emission.z * energy, 0);
        }
    }

    if(auto value = "normal_enabled" in properties)
    {
        if(asBool(*value, "normal_enabled"))
        {
            if(auto texture = "normal_texture" in properties)
            {
                result.normalTexture = asObjectRef(*texture, "normal_texture");
                result.hasNormalTexture = true;
            }

            if(auto scale = "normal_scale" in properties)
                result.material.normalScale = cast(float) asDouble(*scale, "normal_scale");
        }
    }

    if(auto value = "ao_enabled" in properties)
    {
        if(asBool(*value, "ao_enabled"))
        {
            if(auto texture = "ao_texture" in properties)
            {
                result.occlusionTexture = asObjectRef(*texture, "ao_texture");
                result.hasOcclusionTexture = true;
            }

            result.material.occlusionStrength = 1.0f;
        }
    }

    if(auto value = "transparency" in properties)
    {
        with(AlphaMode)
        switch(asLong(*value, "transparency"))
        {
            case 1:
            case 4:
                result.alphaMode = blend;
                break;

            case 2:
            case 3:
                result.alphaMode = mask;
                break;

            default:
                result.alphaMode = opaque;
                break;
        }

        if(auto threshold = "alpha_scissor_threshold" in properties)
            result.material.alphaCutoff = cast(float) asDouble(*threshold, "alpha_scissor_threshold");
    }

    if(auto value = "cull_mode" in properties)
    {
        const mode = asLong(*value, "cull_mode");
        result.doubleSided = mode == 2 || mode == 1;
    }

    if(auto value = "shading_mode" in properties)
        if(asLong(*value, "shading_mode") == 0)
            result.material.mode = MaterialMode.unlit;

    if(type == "ORMMaterial3D")
    {
        if(auto texture = "orm_texture" in properties)
        {
            const textureRef = asObjectRef(*texture, "orm_texture");
            result.metallicTexture = textureRef;
            result.roughnessTexture = textureRef;
            result.occlusionTexture = textureRef;
            result.hasMetallicTexture = true;
            result.hasRoughnessTexture = true;
            result.hasOcclusionTexture = true;
            result.metallicChannel = 2; // blue
            result.roughnessChannel = 1; // green
            result.occlusionChannel = 0; // red
            result.material.metallic = 1.0f;
            result.material.roughness = 1.0f;
            result.material.occlusionStrength = 1.0f;
        }
    }

    result.material.uvTransform = result.uvTransform;
    result.material.textureChannels = Vector4i(
        result.metallicChannel,
        result.roughnessChannel,
        result.occlusionChannel,
        0,
    );
    result.material.alphaMode = result.alphaMode;
    return result;
}

private long propertyLong(in GodotVariant[string] properties, string name, long defaultValue)
{
    auto value = name in properties;
    return value is null ? defaultValue : asLong(*value, name);
}
