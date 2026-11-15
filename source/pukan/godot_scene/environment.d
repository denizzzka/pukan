module pukan.godot_scene.environment;

import dlib.math: Vector3f;
import pukan.godot_scene.value;

/// Godot's Environment.background_mode
enum GodotBackgroundMode: uint
{
    clearColor,
    color,
    sky,
    canvas,
    keep,
    cameraFeed,
}

/// Godot's Environment.ambient_light_source
enum GodotAmbientSource: uint
{
    background,
    disabled,
    color,
    sky,
}

/// Colours of a procedural or approximate sky
struct GodotSky
{
    bool present;
    Vector3f topColor = Vector3f(0.35f, 0.45f, 0.65f);
    Vector3f horizonColor = Vector3f(0.7f, 0.75f, 0.8f);
    Vector3f groundHorizonColor = Vector3f(0.4f, 0.38f, 0.35f);
    Vector3f groundBottomColor = Vector3f(0.15f, 0.14f, 0.13f);
    float energy = 1.0f;
}

/// Godot's Environment.fog_*: a distance fog with an optional ground layer
struct GodotFog
{
    bool enabled;
    Vector3f lightColor = Vector3f(0.5f, 0.6f, 0.7f);
    float lightEnergy = 1.0f;
    /// Extinction per metre
    float density = 0.01f;
    float height = 0.0f;
    float heightDensity = 0.0f;
    float skyAffect = 1.0f;
}

/// Godot's Environment.volumetric_fog_*
struct GodotVolumetricFog
{
    bool enabled;
    /// Extinction per metre
    float density = 0.05f;
    Vector3f albedo = Vector3f(1.0f, 1.0f, 1.0f);
    Vector3f emission = Vector3f(0.0f, 0.0f, 0.0f);
    float emissionEnergy = 0.0f;
    float anisotropy = 0.0f;
    /// Farthest distance the fog covers
    float length = 64.0f;
    /// Fraction of the plain sky the fog replaces
    float skyAffect = 1.0f;
}

/// Environment state read from a Godot Environment resource
struct GodotEnvironment
{
    bool present;
    GodotBackgroundMode backgroundMode = GodotBackgroundMode.clearColor;
    Vector3f backgroundColor = Vector3f(0.3f, 0.3f, 0.3f);
    float backgroundEnergy = 1.0f;
    GodotSky sky;

    GodotAmbientSource ambientSource = GodotAmbientSource.background;
    Vector3f ambientColor = Vector3f(1, 1, 1);
    float ambientEnergy = 1.0f;

    /// Godot's tonemap_mode: linear, Reinhard, Filmic, ACES, AgX
    uint tonemapMode = 0;
    float exposure = 1.0f;
    float white = 1.0f;

    GodotFog fog;
    GodotVolumetricFog volumetricFog;
}

/// Reads an Environment resource; other types return an absent result
GodotEnvironment readGodotEnvironment(string type, in GodotVariant[string] properties)
{
    GodotEnvironment result;

    if(type != "Environment")
        return result;

    result.present = true;
    result.backgroundMode = cast(GodotBackgroundMode) propertyLong(properties, "background_mode", 0);
    result.backgroundColor = propertyColor(properties, "background_color", result.backgroundColor);
    result.backgroundEnergy = cast(float) propertyDouble(properties, "background_energy_multiplier", 1.0);

    result.ambientSource = cast(GodotAmbientSource) propertyLong(properties, "ambient_light_source", 0);
    result.ambientColor = propertyColor(properties, "ambient_light_color", result.ambientColor);
    result.ambientEnergy = cast(float) propertyDouble(properties, "ambient_light_energy", 1.0);

    result.tonemapMode = cast(uint) propertyLong(properties, "tonemap_mode", 0);
    result.exposure = cast(float) propertyDouble(properties, "tonemap_exposure", 1.0);
    result.white = cast(float) propertyDouble(properties, "tonemap_white", 1.0);

    result.fog.enabled = propertyBool(properties, "fog_enabled", false);
    result.fog.lightColor = propertyColor(properties, "fog_light_color", result.fog.lightColor);
    result.fog.lightEnergy = cast(float) propertyDouble(properties, "fog_light_energy", 1.0);
    result.fog.density = cast(float) propertyDouble(properties, "fog_density", 0.01);
    result.fog.height = cast(float) propertyDouble(properties, "fog_height", 0.0);
    result.fog.heightDensity = cast(float) propertyDouble(properties, "fog_height_density", 0.0);
    result.fog.skyAffect = cast(float) propertyDouble(properties, "fog_sky_affect", 1.0);

    result.volumetricFog.enabled = propertyBool(properties, "volumetric_fog_enabled", false);
    result.volumetricFog.density = cast(float) propertyDouble(properties, "volumetric_fog_density", 0.05);
    result.volumetricFog.albedo = propertyColor(properties, "volumetric_fog_albedo", result.volumetricFog.albedo);
    result.volumetricFog.emission = propertyColor(properties, "volumetric_fog_emission", result.volumetricFog.emission);
    result.volumetricFog.emissionEnergy = cast(float) propertyDouble(properties, "volumetric_fog_emission_energy", 0.0);
    result.volumetricFog.anisotropy = cast(float) propertyDouble(properties, "volumetric_fog_anisotropy", 0.0);
    result.volumetricFog.length = cast(float) propertyDouble(properties, "volumetric_fog_length", 64.0);
    result.volumetricFog.skyAffect = cast(float) propertyDouble(properties, "volumetric_fog_sky_affect", 1.0);

    return result;
}

/// Reads a Sky resource's material; unsupported materials get the default colours
GodotSky readGodotSky(string type, in GodotVariant[string] properties)
{
    GodotSky result;

    if(type == "ProceduralSkyMaterial")
    {
        result.present = true;
        result.topColor = propertyColor(properties, "sky_top_color", result.topColor);
        result.horizonColor = propertyColor(properties, "sky_horizon_color", result.horizonColor);
        result.groundHorizonColor = propertyColor(properties, "ground_horizon_color", result.groundHorizonColor);
        result.groundBottomColor = propertyColor(properties, "ground_bottom_color", result.groundBottomColor);
        result.energy = cast(float) propertyDouble(properties, "sky_energy_multiplier", 1.0);
    }
    else if(type == "PhysicalSkyMaterial")
    {
        // Physically based parameters have no direct colour equivalent
        result.present = true;
    }
    else if(type == "ShaderMaterial")
    {
        // A custom sky shader cannot run here, so keep a neutral sky
        result.present = true;
    }

    return result;
}

private Vector3f propertyColor(in GodotVariant[string] properties, string name, Vector3f defaultValue)
{
    auto value = name in properties;
    if(value is null)
        return defaultValue;

    const color = as!(GodotColor)(*value, name).toVector4();
    return Vector3f(color.x, color.y, color.z);
}

private bool propertyBool(in GodotVariant[string] properties, string name, bool defaultValue)
{
    auto value = name in properties;
    return value is null ? defaultValue : asBool(*value, name);
}

private double propertyDouble(in GodotVariant[string] properties, string name, double defaultValue)
{
    auto value = name in properties;
    return value is null ? defaultValue : asDouble(*value, name);
}

private long propertyLong(in GodotVariant[string] properties, string name, long defaultValue)
{
    auto value = name in properties;
    return value is null ? defaultValue : asLong(*value, name);
}

unittest
{
    GodotVariant[string] properties;
    properties["background_mode"] = GodotVariant(2L);
    properties["background_energy_multiplier"] = GodotVariant(0.5);
    properties["tonemap_mode"] = GodotVariant(4L);

    const environment = readGodotEnvironment("Environment", properties);
    assert(environment.present);
    assert(environment.backgroundMode == GodotBackgroundMode.sky);
    assert(environment.backgroundEnergy == 0.5f);
    assert(environment.tonemapMode == 4);
    assert(!environment.fog.enabled);
    assert(environment.fog.density == 0.01f);
    assert(!environment.volumetricFog.enabled);
    assert(environment.volumetricFog.length == 64.0f);

    assert(!readGodotEnvironment("NotEnvironment", properties).present);

    properties["fog_enabled"] = GodotVariant(true);
    properties["fog_density"] = GodotVariant(0.04);
    properties["fog_height"] = GodotVariant(1.5);
    properties["fog_height_density"] = GodotVariant(0.6);

    properties["volumetric_fog_enabled"] = GodotVariant(true);
    properties["volumetric_fog_density"] = GodotVariant(0.25);
    properties["volumetric_fog_anisotropy"] = GodotVariant(0.4);

    const fogged = readGodotEnvironment("Environment", properties);
    assert(fogged.fog.enabled);
    assert(fogged.fog.density == 0.04f);
    assert(fogged.fog.height == 1.5f);
    assert(fogged.fog.heightDensity == 0.6f);
    assert(fogged.volumetricFog.enabled);
    assert(fogged.volumetricFog.density == 0.25f);
    assert(fogged.volumetricFog.anisotropy == 0.4f);
}
