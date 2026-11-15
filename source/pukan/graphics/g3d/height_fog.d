module pukan.graphics.g3d.height_fog;

import dlib.math: Vector3f;

/// Godot's Environment.fog_*: an analytic layer that thins with height
struct HeightFog
{
    bool enabled;
    /// Extinction per metre at the layer's reference height
    float density = 0.02f;
    /// Height the layer is densest at
    float height = 0.0f;
    /// How fast the density falls with each metre above `height`
    float falloff = 0.35f;
    /// Light the layer adds, in the scene's own units
    Vector3f color = Vector3f(0.55f, 0.62f, 0.72f);
}

unittest
{
    HeightFog fog;
    assert(!fog.enabled);
    assert(fog.density == 0.02f);
    assert(fog.height == 0.0f);
    assert(fog.falloff > 0.0f);
}
