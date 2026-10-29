module pukan.godot_scene.primitives;

import dlib.math: Vector2f, Vector3f, cross, dot;
import pukan.godot_scene.value;
import pukan.misc: Boxf;
import pukan.pbr.mesh: MeshGeometry;
import std.algorithm: min, max;
import std.math: PI, cos, sin;

/// Whether the resource type is a primitive mesh handled here
bool isPrimitiveMesh(string type)
{
    switch(type)
    {
        case "BoxMesh":
        case "PlaneMesh":
        case "QuadMesh":
        case "SphereMesh":
        case "CylinderMesh":
        case "TorusMesh":
        case "CapsuleMesh":
        case "PrismMesh":
            return true;
        default:
            return false;
    }
}

MeshGeometry decodePrimitiveMesh(string type, in GodotVariant[string] properties)
{
    MeshGeometry result;
    const flipFaces = propertyBool(properties, "flip_faces", false);

    switch(type)
    {
        case "BoxMesh": makeBox(result, properties); break;
        case "PlaneMesh": makePlane(result, properties, false); break;
        case "QuadMesh": makePlane(result, properties, true); break;
        case "SphereMesh": makeSphere(result, properties); break;
        case "CylinderMesh": makeCylinder(result, properties); break;
        case "TorusMesh": makeTorus(result, properties); break;
        case "CapsuleMesh": makeCapsule(result, properties); break;
        case "PrismMesh": makePrism(result, properties); break;
        default: assert(0);
    }

    if(flipFaces)
        flipTriangles(result.indices);

    result.aabb = calculateAabb(result.positions);
    return result;
}

private const(GodotVariant)* find(in GodotVariant[string] properties, string name)
{
    return name in properties;
}

private double propertyDouble(in GodotVariant[string] properties, string name, double defaultValue)
{
    auto value = find(properties, name);
    return value is null ? defaultValue : asDouble(*value, name);
}

private bool propertyBool(in GodotVariant[string] properties, string name, bool defaultValue)
{
    auto value = find(properties, name);
    return value is null ? defaultValue : asBool(*value, name);
}

private long propertyLong(in GodotVariant[string] properties, string name, long defaultValue)
{
    auto value = find(properties, name);
    return value is null ? defaultValue : asLong(*value, name);
}

private Vector2f propertyVector2(in GodotVariant[string] properties, string name, Vector2f defaultValue)
{
    auto value = find(properties, name);
    return value is null ? defaultValue : as!(Vector2f)(*value, name);
}

private Vector3f propertyVector3(in GodotVariant[string] properties, string name, Vector3f defaultValue)
{
    auto value = find(properties, name);
    return value is null ? defaultValue : as!(Vector3f)(*value, name);
}

private Boxf calculateAabb(in Vector3f[] positions)
{
    Boxf result;

    if(positions.length == 0)
        return result;

    result.min = positions[0];
    result.max = positions[0];

    foreach(position; positions[1 .. $])
    {
        result.min.x = min(result.min.x, position.x);
        result.min.y = min(result.min.y, position.y);
        result.min.z = min(result.min.z, position.z);
        result.max.x = max(result.max.x, position.x);
        result.max.y = max(result.max.y, position.y);
        result.max.z = max(result.max.z, position.z);
    }

    return result;
}

private void addQuad(
    ref MeshGeometry geometry,
    Vector3f p0, Vector3f p1, Vector3f p2, Vector3f p3,
    Vector3f n0, Vector3f n1, Vector3f n2, Vector3f n3,
    Vector2f uv0, Vector2f uv1, Vector2f uv2, Vector2f uv3,
)
{
    const uint base = cast(uint) geometry.positions.length;

    geometry.positions ~= [p0, p1, p2, p3];
    geometry.normals ~= [n0, n1, n2, n3];
    geometry.texCoords ~= [uv0, uv1, uv2, uv3];

    const faceNormal = cross(p1 - p0, p2 - p0);

    if(dot(faceNormal, n0) > 0)
        geometry.indices ~= [base, base + 2, base + 1, base, base + 3, base + 2];
    else
        geometry.indices ~= [base, base + 1, base + 2, base, base + 2, base + 3];
}

private void addTriangle(
    ref MeshGeometry geometry,
    Vector3f p0, Vector3f p1, Vector3f p2,
    Vector3f n0, Vector3f n1, Vector3f n2,
    Vector2f uv0, Vector2f uv1, Vector2f uv2,
)
{
    const uint base = cast(uint) geometry.positions.length;

    geometry.positions ~= [p0, p1, p2];
    geometry.normals ~= [n0, n1, n2];
    geometry.texCoords ~= [uv0, uv1, uv2];

    if(dot(cross(p1 - p0, p2 - p0), n0) > 0)
        geometry.indices ~= [base, base + 2, base + 1];
    else
        geometry.indices ~= [base, base + 1, base + 2];
}

private void flipTriangles(ref uint[] indices)
{
    for(size_t i = 0; i + 2 < indices.length; i += 3)
    {
        const tmp = indices[i + 1];
        indices[i + 1] = indices[i + 2];
        indices[i + 2] = tmp;
    }
}

private void makeBox(ref MeshGeometry geometry, in GodotVariant[string] properties)
{
    const size = propertyVector3(properties, "size", Vector3f(1, 1, 1));
    const half = size / 2;

    void face(
        Vector3f center,
        Vector3f u,
        Vector3f v,
        Vector3f normal,
    )
    {
        const p0 = center - u - v;
        const p1 = center + u - v;
        const p2 = center + u + v;
        const p3 = center - u + v;

        addQuad(geometry, p0, p1, p2, p3,
            normal, normal, normal, normal,
            Vector2f(0, 0), Vector2f(1, 0), Vector2f(1, 1), Vector2f(0, 1));
    }

    face(Vector3f(half.x, 0, 0), Vector3f(0, 0, -half.z), Vector3f(0, half.y, 0), Vector3f(1, 0, 0));
    face(Vector3f(-half.x, 0, 0), Vector3f(0, 0, half.z), Vector3f(0, half.y, 0), Vector3f(-1, 0, 0));
    face(Vector3f(0, half.y, 0), Vector3f(half.x, 0, 0), Vector3f(0, 0, -half.z), Vector3f(0, 1, 0));
    face(Vector3f(0, -half.y, 0), Vector3f(half.x, 0, 0), Vector3f(0, 0, half.z), Vector3f(0, -1, 0));
    face(Vector3f(0, 0, half.z), Vector3f(half.x, 0, 0), Vector3f(0, half.y, 0), Vector3f(0, 0, 1));
    face(Vector3f(0, 0, -half.z), Vector3f(-half.x, 0, 0), Vector3f(0, half.y, 0), Vector3f(0, 0, -1));
}

private void makePlane(ref MeshGeometry geometry, in GodotVariant[string] properties, bool quad)
{
    const size = propertyVector2(properties, "size", Vector2f(1, 1));
    const center = propertyVector3(properties, "center_offset", Vector3f(0, 0, 0));
    const orientation = cast(int) propertyLong(properties, "orientation", quad ? 2 : 1);

    Vector3f p0, p1, p2, p3;
    Vector3f normal;

    switch(orientation)
    {
        case 0: // FACE_X
            p0 = Vector3f(0, -size.y / 2, -size.x / 2);
            p1 = Vector3f(0, -size.y / 2, size.x / 2);
            p2 = Vector3f(0, size.y / 2, size.x / 2);
            p3 = Vector3f(0, size.y / 2, -size.x / 2);
            normal = Vector3f(1, 0, 0);
            break;

        case 1: // FACE_Y
            p0 = Vector3f(-size.x / 2, 0, -size.y / 2);
            p1 = Vector3f(size.x / 2, 0, -size.y / 2);
            p2 = Vector3f(size.x / 2, 0, size.y / 2);
            p3 = Vector3f(-size.x / 2, 0, size.y / 2);
            normal = Vector3f(0, 1, 0);
            break;

        case 2: // FACE_Z
            p0 = Vector3f(-size.x / 2, -size.y / 2, 0);
            p1 = Vector3f(size.x / 2, -size.y / 2, 0);
            p2 = Vector3f(size.x / 2, size.y / 2, 0);
            p3 = Vector3f(-size.x / 2, size.y / 2, 0);
            normal = Vector3f(0, 0, 1);
            break;

        default:
            assert(0);
    }

    addQuad(geometry, center + p0, center + p1, center + p2, center + p3,
        normal, normal, normal, normal,
        Vector2f(0, 0), Vector2f(1, 0), Vector2f(1, 1), Vector2f(0, 1));
}

private void makeSphere(ref MeshGeometry geometry, in GodotVariant[string] properties)
{
    const radius = cast(float) propertyDouble(properties, "radius", 0.5);
    const halfHeight = cast(float) propertyDouble(properties, "height", 1.0) / 2;
    const segments = cast(int) propertyLong(properties, "radial_segments", 64);
    const rings = cast(int) propertyLong(properties, "rings", 32);
    const hemisphere = propertyBool(properties, "is_hemisphere", false);

    if(segments < 3 || rings < 1)
        return;

    Vector3f point(size_t ring, size_t segment)
    {
        const v = cast(float) ring / rings;
        const theta = (hemisphere ? PI / 2 : PI) * v;
        const phi = 2 * PI * segment / segments;

        return Vector3f(
            radius * sin(theta) * cos(phi),
            halfHeight * cos(theta),
            radius * sin(theta) * sin(phi),
        );
    }

    Vector3f normal(Vector3f p)
    {
        return Vector3f(p.x / (radius * radius), p.y / (halfHeight * halfHeight), p.z / (radius * radius)).normalized;
    }

    foreach(ring; 0 .. rings)
    {
        foreach(segment; 0 .. segments)
        {
            const p0 = point(ring, segment);
            const p1 = point(ring + 1, segment);
            const p2 = point(ring + 1, segment + 1);
            const p3 = point(ring, segment + 1);

            addQuad(geometry, p0, p1, p2, p3,
                normal(p0), normal(p1), normal(p2), normal(p3),
                Vector2f(cast(float) segment / segments, cast(float) ring / rings),
                Vector2f(cast(float) segment / segments, cast(float) (ring + 1) / rings),
                Vector2f(cast(float) (segment + 1) / segments, cast(float) (ring + 1) / rings),
                Vector2f(cast(float) (segment + 1) / segments, cast(float) ring / rings),
            );
        }
    }
}

private void makeCylinder(ref MeshGeometry geometry, in GodotVariant[string] properties)
{
    const topRadius = cast(float) propertyDouble(properties, "top_radius", 0.5);
    const bottomRadius = cast(float) propertyDouble(properties, "bottom_radius", 0.5);
    const height = cast(float) propertyDouble(properties, "height", 2.0);
    const segments = cast(int) propertyLong(properties, "radial_segments", 64);
    const rings = cast(int) propertyLong(properties, "rings", 4);
    const capTop = propertyBool(properties, "cap_top", true);
    const capBottom = propertyBool(properties, "cap_bottom", true);

    if(segments < 3 || rings < 1)
        return;

    Vector3f point(size_t ring, size_t segment)
    {
        const t = cast(float) ring / rings;
        const radius = bottomRadius + (topRadius - bottomRadius) * t;
        const phi = 2 * PI * segment / segments;

        return Vector3f(radius * cos(phi), -height / 2 + height * t, radius * sin(phi));
    }

    Vector3f normal(size_t segment)
    {
        const phi = 2 * PI * segment / segments;
        const slope = (topRadius - bottomRadius) / height;

        return Vector3f(cos(phi), -slope, sin(phi)).normalized;
    }

    foreach(ring; 0 .. rings)
    {
        foreach(segment; 0 .. segments)
        {
            const p0 = point(ring, segment);
            const p1 = point(ring + 1, segment);
            const p2 = point(ring + 1, segment + 1);
            const p3 = point(ring, segment + 1);

            addQuad(geometry, p0, p1, p2, p3,
                normal(segment), normal(segment), normal(segment + 1), normal(segment + 1),
                Vector2f(cast(float) segment / segments, cast(float) ring / rings),
                Vector2f(cast(float) segment / segments, cast(float) (ring + 1) / rings),
                Vector2f(cast(float) (segment + 1) / segments, cast(float) (ring + 1) / rings),
                Vector2f(cast(float) (segment + 1) / segments, cast(float) ring / rings),
            );
        }
    }

    void cap(float y, float radius, Vector3f normal, bool enabled)
    {
        if(!enabled || radius == 0)
            return;

        const center = Vector3f(0, y, 0);

        foreach(segment; 0 .. segments)
        {
            const phi0 = 2 * PI * segment / segments;
            const phi1 = 2 * PI * (segment + 1) / segments;
            const p0 = Vector3f(radius * cos(phi0), y, radius * sin(phi0));
            const p1 = Vector3f(radius * cos(phi1), y, radius * sin(phi1));

            addTriangle(geometry, center, p0, p1, normal, normal, normal,
                Vector2f(0.5, 0.5),
                Vector2f(0.5 + cos(phi0) * 0.5, 0.5 + sin(phi0) * 0.5),
                Vector2f(0.5 + cos(phi1) * 0.5, 0.5 + sin(phi1) * 0.5),
            );
        }
    }

    cap(height / 2, topRadius, Vector3f(0, 1, 0), capTop);
    cap(-height / 2, bottomRadius, Vector3f(0, -1, 0), capBottom);
}

private void makeTorus(ref MeshGeometry geometry, in GodotVariant[string] properties)
{
    const inner = cast(float) propertyDouble(properties, "inner_radius", 0.5);
    const outer = cast(float) propertyDouble(properties, "outer_radius", 1.0);
    const rings = cast(int) propertyLong(properties, "rings", 64);
    const ringSegments = cast(int) propertyLong(properties, "ring_segments", 32);

    if(rings < 3 || ringSegments < 3)
        return;

    const majorRadius = (inner + outer) / 2;
    const minorRadius = (outer - inner) / 2;

    Vector3f point(size_t ring, size_t segment)
    {
        const u = 2 * PI * ring / rings;
        const v = 2 * PI * segment / ringSegments;

        return Vector3f(
            (majorRadius + minorRadius * cos(v)) * cos(u),
            minorRadius * sin(v),
            (majorRadius + minorRadius * cos(v)) * sin(u),
        );
    }

    Vector3f normal(size_t ring, size_t segment)
    {
        const u = 2 * PI * ring / rings;
        const v = 2 * PI * segment / ringSegments;

        return Vector3f(cos(v) * cos(u), sin(v), cos(v) * sin(u));
    }

    foreach(ring; 0 .. rings)
    {
        foreach(segment; 0 .. ringSegments)
        {
            const p0 = point(ring, segment);
            const p1 = point(ring + 1, segment);
            const p2 = point(ring + 1, segment + 1);
            const p3 = point(ring, segment + 1);

            addQuad(geometry, p0, p1, p2, p3,
                normal(ring, segment), normal(ring + 1, segment),
                normal(ring + 1, segment + 1), normal(ring, segment + 1),
                Vector2f(cast(float) ring / rings, cast(float) segment / ringSegments),
                Vector2f(cast(float) (ring + 1) / rings, cast(float) segment / ringSegments),
                Vector2f(cast(float) (ring + 1) / rings, cast(float) (segment + 1) / ringSegments),
                Vector2f(cast(float) ring / rings, cast(float) (segment + 1) / ringSegments),
            );
        }
    }
}

private void makeCapsule(ref MeshGeometry geometry, in GodotVariant[string] properties)
{
    // Approximated by an ellipsoid; enough to show the node and its material.
    const radius = cast(float) propertyDouble(properties, "radius", 0.5);
    const height = cast(float) propertyDouble(properties, "height", 2.0);
    const segments = cast(int) propertyLong(properties, "radial_segments", 64);
    const rings = cast(int) propertyLong(properties, "rings", 32);

    if(segments < 3 || rings < 1)
        return;

    const halfHeight = height / 2;

    Vector3f point(size_t ring, size_t segment)
    {
        const theta = PI * ring / rings;
        const phi = 2 * PI * segment / segments;

        return Vector3f(
            radius * sin(theta) * cos(phi),
            halfHeight * cos(theta),
            radius * sin(theta) * sin(phi),
        );
    }

    foreach(ring; 0 .. rings)
    {
        foreach(segment; 0 .. segments)
        {
            const p0 = point(ring, segment);
            const p1 = point(ring + 1, segment);
            const p2 = point(ring + 1, segment + 1);
            const p3 = point(ring, segment + 1);

            addQuad(geometry, p0, p1, p2, p3,
                p0.normalized, p1.normalized, p2.normalized, p3.normalized,
                Vector2f(cast(float) segment / segments, cast(float) ring / rings),
                Vector2f(cast(float) segment / segments, cast(float) (ring + 1) / rings),
                Vector2f(cast(float) (segment + 1) / segments, cast(float) (ring + 1) / rings),
                Vector2f(cast(float) (segment + 1) / segments, cast(float) ring / rings),
            );
        }
    }
}

private void makePrism(ref MeshGeometry geometry, in GodotVariant[string] properties)
{
    const size = propertyVector3(properties, "size", Vector3f(1, 1, 1));
    const half = size / 2;
    const left = cast(float) propertyDouble(properties, "left_to_right", 0.5) * size.x - half.x;

    const p0 = Vector3f(-half.x, -half.y, -half.z);
    const p1 = Vector3f(left, half.y, -half.z);
    const p2 = Vector3f(-half.x, -half.y, half.z);
    const p3 = Vector3f(-half.x, half.y, -half.z);
    const p4 = Vector3f(left, half.y, half.z);
    const p5 = Vector3f(-half.x, half.y, half.z);

    addTriangle(geometry, p0, p3, p1, Vector3f(0, 0, -1), Vector3f(0, 0, -1), Vector3f(0, 0, -1),
        Vector2f(0, 0), Vector2f(0, 1), Vector2f(1, 1));
    addTriangle(geometry, p2, p4, p5, Vector3f(0, 0, 1), Vector3f(0, 0, 1), Vector3f(0, 0, 1),
        Vector2f(0, 0), Vector2f(1, 1), Vector2f(0, 1));
    addQuad(geometry, p0, p1, p4, p2,
        Vector3f(-1, 0, 0), Vector3f(-1, 0, 0), Vector3f(-1, 0, 0), Vector3f(-1, 0, 0),
        Vector2f(0, 0), Vector2f(1, 0), Vector2f(1, 1), Vector2f(0, 1));
    addQuad(geometry, p0, p2, p5, p3,
        Vector3f(0, -1, 0), Vector3f(0, -1, 0), Vector3f(0, -1, 0), Vector3f(0, -1, 0),
        Vector2f(0, 0), Vector2f(1, 0), Vector2f(1, 1), Vector2f(0, 1));
    addQuad(geometry, p1, p3, p5, p4,
        Vector3f(0, 1, 0), Vector3f(0, 1, 0), Vector3f(0, 1, 0), Vector3f(0, 1, 0),
        Vector2f(0, 0), Vector2f(1, 0), Vector2f(1, 1), Vector2f(0, 1));
}
