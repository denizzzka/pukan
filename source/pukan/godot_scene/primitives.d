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
    const subdivideW = max(cast(int) propertyLong(properties, "subdivide_width", 0), 0);
    const subdivideH = max(cast(int) propertyLong(properties, "subdivide_height", 0), 0);
    const subdivideD = max(cast(int) propertyLong(properties, "subdivide_depth", 0), 0);

    void face(
        Vector3f center,
        Vector3f u,
        Vector3f v,
        Vector3f normal,
        int columns,
        int rows,
    )
    {
        Vector3f point(int column, int row)
        {
            const fu = cast(float) column / (columns + 1);
            const fv = cast(float) row / (rows + 1);
            return center + (fu * 2 - 1) * u + (fv * 2 - 1) * v;
        }

        foreach(row; 0 .. rows + 1)
        {
            foreach(column; 0 .. columns + 1)
            {
                const u0 = cast(float) column / (columns + 1);
                const v0 = cast(float) row / (rows + 1);
                const u1 = cast(float) (column + 1) / (columns + 1);
                const v1 = cast(float) (row + 1) / (rows + 1);

                addQuad(geometry,
                    point(column, row), point(column + 1, row),
                    point(column + 1, row + 1), point(column, row + 1),
                    normal, normal, normal, normal,
                    Vector2f(u0, v0), Vector2f(u1, v0), Vector2f(u1, v1), Vector2f(u0, v1),
                );
            }
        }
    }

    face(Vector3f(half.x, 0, 0), Vector3f(0, 0, -half.z), Vector3f(0, half.y, 0), Vector3f(1, 0, 0),
        subdivideD, subdivideH);
    face(Vector3f(-half.x, 0, 0), Vector3f(0, 0, half.z), Vector3f(0, half.y, 0), Vector3f(-1, 0, 0),
        subdivideD, subdivideH);
    face(Vector3f(0, half.y, 0), Vector3f(half.x, 0, 0), Vector3f(0, 0, -half.z), Vector3f(0, 1, 0),
        subdivideW, subdivideD);
    face(Vector3f(0, -half.y, 0), Vector3f(half.x, 0, 0), Vector3f(0, 0, half.z), Vector3f(0, -1, 0),
        subdivideW, subdivideD);
    face(Vector3f(0, 0, half.z), Vector3f(half.x, 0, 0), Vector3f(0, half.y, 0), Vector3f(0, 0, 1),
        subdivideW, subdivideH);
    face(Vector3f(0, 0, -half.z), Vector3f(-half.x, 0, 0), Vector3f(0, half.y, 0), Vector3f(0, 0, -1),
        subdivideW, subdivideH);
}

private void makePlane(ref MeshGeometry geometry, in GodotVariant[string] properties, bool quad)
{
    const size = propertyVector2(properties, "size", Vector2f(1, 1));
    const center = propertyVector3(properties, "center_offset", Vector3f(0, 0, 0));
    const orientation = cast(int) propertyLong(properties, "orientation", quad ? 2 : 1);
    const subdivideW = max(cast(int) propertyLong(properties, "subdivide_width", 0), 0);
    const subdivideD = max(cast(int) propertyLong(properties, "subdivide_depth", 0), 0);

    Vector3f normal;
    Vector3f point(float u, float v)
    {
        switch(orientation)
        {
            case 0: // FACE_X
                normal = Vector3f(1, 0, 0);
                return center + Vector3f(0, (v - 0.5f) * size.y, (u - 0.5f) * size.x);

            case 1: // FACE_Y
                normal = Vector3f(0, 1, 0);
                return center + Vector3f((u - 0.5f) * size.x, 0, (v - 0.5f) * size.y);

            case 2: // FACE_Z
                normal = Vector3f(0, 0, 1);
                return center + Vector3f((u - 0.5f) * size.x, (v - 0.5f) * size.y, 0);

            default:
                assert(0);
        }
    }

    foreach(row; 0 .. subdivideD + 1)
    {
        foreach(column; 0 .. subdivideW + 1)
        {
            const u0 = cast(float) column / (subdivideW + 1);
            const v0 = cast(float) row / (subdivideD + 1);
            const u1 = cast(float) (column + 1) / (subdivideW + 1);
            const v1 = cast(float) (row + 1) / (subdivideD + 1);

            addQuad(geometry,
                point(u0, v0), point(u1, v0), point(u1, v1), point(u0, v1),
                normal, normal, normal, normal,
                Vector2f(u0, v0), Vector2f(u1, v0), Vector2f(u1, v1), Vector2f(u0, v1),
            );
        }
    }
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
    const radius = min(cast(float) propertyDouble(properties, "radius", 0.5),
        cast(float) propertyDouble(properties, "height", 2.0) / 2);
    const height = cast(float) propertyDouble(properties, "height", 2.0);
    const segments = cast(int) propertyLong(properties, "radial_segments", 64);
    const rings = max(cast(int) propertyLong(properties, "rings", 32), 0);

    if(segments < 3)
        return;

    const halfHeight = height / 2;
    const cylinderHeight = height - 2 * radius;

    Vector3f radial(float u)
    {
        return Vector3f(-sin(u * 2 * PI), 0, cos(u * 2 * PI));
    }

    // Top hemisphere, cylinder and bottom hemisphere share the seam rows.
    void section(float yOffset, bool top, ref MeshGeometry target)
    {
        Vector3f point(int ring, int segment)
        {
            const v = cast(float) ring / (rings + 1);
            const u = cast(float) segment / segments;
            const direction = radial(u);

            if(top)
            {
                const w = sin(0.5f * PI * v);
                const y = cos(0.5f * PI * v);
                return Vector3f(direction.x * w, y, direction.z * w) * radius +
                    Vector3f(0, yOffset, 0);
            }
            else
            {
                const w = cos(0.5f * PI * v);
                const y = -sin(0.5f * PI * v);
                return Vector3f(direction.x * w, y, direction.z * w) * radius +
                    Vector3f(0, yOffset, 0);
            }
        }

        Vector3f normal(int ring, int segment)
        {
            const v = cast(float) ring / (rings + 1);
            const u = cast(float) segment / segments;

            if(top)
            {
                const w = sin(0.5f * PI * v);
                const y = cos(0.5f * PI * v);
                return Vector3f(radial(u).x * w, y, radial(u).z * w);
            }
            else
            {
                const w = cos(0.5f * PI * v);
                const y = -sin(0.5f * PI * v);
                return Vector3f(radial(u).x * w, y, radial(u).z * w);
            }
        }

        foreach(ring; 0 .. rings + 1)
        {
            foreach(segment; 0 .. segments)
            {
                const u0 = cast(float) segment / segments;
                const u1 = cast(float) (segment + 1) / segments;
                const v0 = cast(float) ring / (rings + 1);
                const v1 = cast(float) (ring + 1) / (rings + 1);

                addQuad(target,
                    point(ring, segment), point(ring + 1, segment),
                    point(ring + 1, segment + 1), point(ring, segment + 1),
                    normal(ring, segment), normal(ring + 1, segment),
                    normal(ring + 1, segment + 1), normal(ring, segment + 1),
                    Vector2f(u0, v0), Vector2f(u0, v1), Vector2f(u1, v1), Vector2f(u1, v0),
                );
            }
        }
    }

    section(halfHeight - radius, true, geometry);

    // Cylinder
    foreach(ring; 0 .. rings + 1)
    {
        const v0 = cast(float) ring / (rings + 1);
        const v1 = cast(float) (ring + 1) / (rings + 1);
        const y0 = halfHeight - radius - cylinderHeight * v0;
        const y1 = halfHeight - radius - cylinderHeight * v1;

        foreach(segment; 0 .. segments)
        {
            const u0 = cast(float) segment / segments;
            const u1 = cast(float) (segment + 1) / segments;
            const d0 = radial(u0);
            const d1 = radial(u1);

            addQuad(geometry,
                Vector3f(d0.x * radius, y0, d0.z * radius),
                Vector3f(d0.x * radius, y1, d0.z * radius),
                Vector3f(d1.x * radius, y1, d1.z * radius),
                Vector3f(d1.x * radius, y0, d1.z * radius),
                d0, d0, d1, d1,
                Vector2f(u0, v0), Vector2f(u0, v1), Vector2f(u1, v1), Vector2f(u1, v0),
            );
        }
    }

    section(-halfHeight + radius, false, geometry);
}

private void makePrism(ref MeshGeometry geometry, in GodotVariant[string] properties)
{
    const size = propertyVector3(properties, "size", Vector3f(1, 1, 1));
    const half = size / 2;
    const leftToRight = cast(float) propertyDouble(properties, "left_to_right", 0.5);
    const subdivideW = max(cast(int) propertyLong(properties, "subdivide_width", 0), 0);
    const subdivideH = max(cast(int) propertyLong(properties, "subdivide_height", 0), 0);
    const subdivideD = max(cast(int) propertyLong(properties, "subdivide_depth", 0), 0);

    // Front and back triangular faces
    foreach(back; 0 .. 2)
    {
        const z = back ? half.z : -half.z;
        const normal = Vector3f(0, 0, back ? -1 : 1);

        foreach(row; 0 .. subdivideH + 1)
        {
            const scale0 = cast(float) row / (subdivideH + 1);
            const scale1 = cast(float) (row + 1) / (subdivideH + 1);
            const start0 = -half.x + (1 - scale0) * size.x * leftToRight;
            const start1 = -half.x + (1 - scale1) * size.x * leftToRight;
            const width0 = scale0 * size.x;
            const width1 = scale1 * size.x;
            const y0 = half.y - size.y * scale0;
            const y1 = half.y - size.y * scale1;

            foreach(column; 0 .. subdivideW + 1)
            {
                const u0 = cast(float) column / (subdivideW + 1);
                const u1 = cast(float) (column + 1) / (subdivideW + 1);

                addQuad(geometry,
                    Vector3f(start0 + width0 * u0, y0, z),
                    Vector3f(start0 + width0 * u1, y0, z),
                    Vector3f(start1 + width1 * u1, y1, z),
                    Vector3f(start1 + width1 * u0, y1, z),
                    normal, normal, normal, normal,
                    Vector2f(u0, scale0), Vector2f(u1, scale0),
                    Vector2f(u1, scale1), Vector2f(u0, scale1),
                );
            }
        }
    }

    // Slanted left and right faces
    const leftNormal = Vector3f(-size.y, size.x * leftToRight, 0).normalized;
    const rightNormal = Vector3f(size.y, size.x * (1 - leftToRight), 0).normalized;

    foreach(right; 0 .. 2)
    {
        const normal = right ? rightNormal : leftNormal;

        foreach(row; 0 .. subdivideH + 1)
        {
            const scale0 = cast(float) row / (subdivideH + 1);
            const scale1 = cast(float) (row + 1) / (subdivideH + 1);
            const left0 = -half.x + size.x * (1 - scale0) * leftToRight;
            const left1 = -half.x + size.x * (1 - scale1) * leftToRight;
            const x0 = right ? left0 + size.x * scale0 : left0;
            const x1 = right ? left1 + size.x * scale1 : left1;
            const y0 = half.y - size.y * scale0;
            const y1 = half.y - size.y * scale1;

            foreach(depth; 0 .. subdivideD + 1)
            {
                const v0 = cast(float) depth / (subdivideD + 1);
                const v1 = cast(float) (depth + 1) / (subdivideD + 1);
                const z0 = -half.z + size.z * v0;
                const z1 = -half.z + size.z * v1;

                addQuad(geometry,
                    Vector3f(x0, y0, z0), Vector3f(x1, y1, z0),
                    Vector3f(x1, y1, z1), Vector3f(x0, y0, z1),
                    normal, normal, normal, normal,
                    Vector2f(scale0, v0), Vector2f(scale1, v0),
                    Vector2f(scale1, v1), Vector2f(scale0, v1),
                );
            }
        }
    }

    // Bottom face
    foreach(row; 0 .. subdivideD + 1)
    {
        const v0 = cast(float) row / (subdivideD + 1);
        const v1 = cast(float) (row + 1) / (subdivideD + 1);
        const z0 = -half.z + size.z * v0;
        const z1 = -half.z + size.z * v1;

        foreach(column; 0 .. subdivideW + 1)
        {
            const u0 = cast(float) column / (subdivideW + 1);
            const u1 = cast(float) (column + 1) / (subdivideW + 1);

            addQuad(geometry,
                Vector3f(-half.x + size.x * u0, -half.y, z0),
                Vector3f(-half.x + size.x * u1, -half.y, z0),
                Vector3f(-half.x + size.x * u1, -half.y, z1),
                Vector3f(-half.x + size.x * u0, -half.y, z1),
                Vector3f(0, -1, 0), Vector3f(0, -1, 0), Vector3f(0, -1, 0), Vector3f(0, -1, 0),
                Vector2f(u0, v0), Vector2f(u1, v0), Vector2f(u1, v1), Vector2f(u0, v1),
            );
        }
    }
}

unittest
{
    GodotVariant[string] properties;
    properties["size"] = GodotVariant(Vector3f(1, 1, 1));
    properties["subdivide_width"] = GodotVariant(1L);
    properties["subdivide_height"] = GodotVariant(1L);
    properties["subdivide_depth"] = GodotVariant(1L);

    const box = decodePrimitiveMesh("BoxMesh", properties);
    assert(box.positions.length == 96);
    assert(box.indices.length == 144);

    properties["size"] = GodotVariant(Vector2f(2, 2));
    properties["subdivide_width"] = GodotVariant(2L);
    properties["subdivide_depth"] = GodotVariant(2L);

    const plane = decodePrimitiveMesh("PlaneMesh", properties);
    assert(plane.positions.length == 36);
    assert(plane.indices.length == 54);

    properties = null;
    properties["radius"] = GodotVariant(0.5);
    properties["height"] = GodotVariant(2.0);
    properties["radial_segments"] = GodotVariant(8L);
    properties["rings"] = GodotVariant(2L);

    const capsule = decodePrimitiveMesh("CapsuleMesh", properties);
    assert(capsule.positions.length == 288);
    assert(capsule.indices.length == 432);

    foreach(position; capsule.positions)
    {
        assert(position.y >= -1.001f && position.y <= 1.001f);
        assert(position.x * position.x + position.z * position.z <= 0.251f);
    }

    properties = null;
    properties["size"] = GodotVariant(Vector3f(1.5, 1.5, 1));
    properties["left_to_right"] = GodotVariant(0.3);
    properties["subdivide_width"] = GodotVariant(1L);
    properties["subdivide_height"] = GodotVariant(1L);
    properties["subdivide_depth"] = GodotVariant(1L);

    const prism = decodePrimitiveMesh("PrismMesh", properties);
    assert(prism.positions.length > 0);
    assert(prism.indices.length > 0);
    assert(prism.aabb.max.y == 0.75f);
    assert(prism.aabb.min.y == -0.75f);
    assert(prism.aabb.max.x == 0.75f);
    assert(prism.aabb.min.x == -0.75f);
}
