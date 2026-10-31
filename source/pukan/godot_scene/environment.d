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

    assert(!readGodotEnvironment("NotEnvironment", properties).present);
}
