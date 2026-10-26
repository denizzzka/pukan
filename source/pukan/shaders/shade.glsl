const uint FLAG_NORMALS = 1u << 0; // sync with SphereGroupFlag and CylinderGroupFlag

vec3 shadeSurface(vec3 normal, vec3 base, uint flags)
{
    const vec3 unitNormal = normalize(normal);

    const vec3 debugLook = mix(unitNormal * 0.5 + 0.5, base, 0.2);

    // TODO: world-space light; model-space light rotates with the scene.
    const vec3 lightDirection = normalize(vec3(0.35, 0.5, 0.8));
    const vec3 litLook = base * (0.6 + 0.6 * max(dot(unitNormal, lightDirection), 0.0));

    return mix(debugLook, litLook, float((flags & FLAG_NORMALS) == 0u));
}
