module pukan.physics.shapes;

import dlib.math: Matrix4x4f, Vector3f, Vector4f, cross, dot, translationMatrix;
import std.algorithm: min, max;
import std.math: abs, isNaN, sqrt;

enum ShapeKind
{
    none,
    sphere,
    capsule,
    box,
    cylinder,
    convex,
    triangleMesh,
    plane,
}

/// Axis-aligned bounds with min/max corners
struct Aabb
{
    Vector3f min;
    Vector3f max;

    static Aabb fromPoints(in Vector3f[] points)
    {
        if(points.length == 0)
            return Aabb.init;

        Aabb result = Aabb(points[0], points[0]);

        foreach(p; points[1 .. $])
            result = result.unionWithPoint(p);

        return result;
    }

    static Aabb fromCenterExtent(in Vector3f center, in Vector3f extent)
    {
        return Aabb(center - extent, center + extent);
    }

    bool isValid() const
    {
        return min.x <= max.x && min.y <= max.y && min.z <= max.z;
    }

    Vector3f center() const
    {
        return (min + max) * 0.5f;
    }

    Vector3f size() const
    {
        return max - min;
    }

    Vector3f extent() const
    {
        return size * 0.5f;
    }

    float surfaceArea() const
    {
        const s = size;

        return 2.0f * (s.x * s.y + s.y * s.z + s.z * s.x);
    }

    Aabb unionWith(in Aabb other) const
    {
        if(!isValid())
            return other;
        if(!other.isValid())
            return this;

        return Aabb(
            Vector3f(min.x.min(other.min.x), min.y.min(other.min.y), min.z.min(other.min.z)),
            Vector3f(max.x.max(other.max.x), max.y.max(other.max.y), max.z.max(other.max.z)),
        );
    }

    Aabb unionWithPoint(in Vector3f point) const
    {
        if(!isValid())
            return Aabb(point, point);

        return Aabb(
            Vector3f(min.x.min(point.x), min.y.min(point.y), min.z.min(point.z)),
            Vector3f(max.x.max(point.x), max.y.max(point.y), max.z.max(point.z)),
        );
    }

    Aabb expanded(float margin) const
    {
        const m = Vector3f(margin, margin, margin);

        return Aabb(min - m, max + m);
    }

    Aabb swept(in Vector3f motion) const
    {
        return unionWith(Aabb(min + motion, max + motion));
    }

    bool overlaps(in Aabb other) const
    {
        return min.x <= other.max.x && max.x >= other.min.x
            && min.y <= other.max.y && max.y >= other.min.y
            && min.z <= other.max.z && max.z >= other.min.z;
    }

    bool contains(in Vector3f point) const
    {
        return point.x >= min.x && point.x <= max.x
            && point.y >= min.y && point.y <= max.y
            && point.z >= min.z && point.z <= max.z;
    }
}

/// One collision primitive in a collider's local frame
struct CollisionShape
{
    ShapeKind kind = ShapeKind.none;
    float radius;
    float height;
    Vector3f halfExtents;
    Vector3f[] points;
    Vector3f[] vertices;
    uint[] indices;
    Vector3f planeNormal;
    float planeDistance;

    static CollisionShape sphere(float radius)
    {
        CollisionShape result;
        result.kind = ShapeKind.sphere;
        result.radius = radius;
        return result;
    }

    static CollisionShape capsule(float radius, float height)
    {
        CollisionShape result;
        result.kind = ShapeKind.capsule;
        result.radius = radius;
        result.height = height;
        return result;
    }

    static CollisionShape box(Vector3f size)
    {
        CollisionShape result;
        result.kind = ShapeKind.box;
        result.halfExtents = size * 0.5f;
        return result;
    }

    static CollisionShape cylinder(float radius, float height)
    {
        CollisionShape result;
        result.kind = ShapeKind.cylinder;
        result.radius = radius;
        result.height = height;
        return result;
    }

    static CollisionShape convex(Vector3f[] points)
    {
        CollisionShape result;
        result.kind = ShapeKind.convex;
        result.points = points;
        return result;
    }

    static CollisionShape triangleMesh(Vector3f[] vertices, uint[] indices)
    {
        CollisionShape result;
        result.kind = ShapeKind.triangleMesh;
        result.vertices = vertices;
        result.indices = indices;
        return result;
    }

    static CollisionShape plane(Vector3f normal, float distance)
    {
        CollisionShape result;
        result.kind = ShapeKind.plane;
        result.planeNormal = normal;
        result.planeDistance = distance;
        return result;
    }

    /// Half length of the capsule's inner segment
    float capsuleHalfSegment() const
    {
        return max(height * 0.5f - radius, 0.0f);
    }

    Aabb bounds(in Matrix4x4f transform) const
    {
        final switch(kind)
        {
            case ShapeKind.none:
                return Aabb.init;

            case ShapeKind.sphere:
            {
                const center = Vector3f(transform.a14, transform.a24, transform.a34);
                return Aabb.fromCenterExtent(center, Vector3f(radius, radius, radius));
            }

            case ShapeKind.capsule:
            {
                const half = capsuleHalfSegment();
                const a = transformPoint(Vector3f(0, -half, 0), transform);
                const b = transformPoint(Vector3f(0, half, 0), transform);
                const point = Aabb.fromPoints([a, b]);

                return point.expanded(radius);
            }

            case ShapeKind.box:
            {
                Vector3f[8] corners;

                foreach(i; 0 .. 8)
                    corners[i] = transformPoint(Vector3f(
                        (i & 1) ? halfExtents.x : -halfExtents.x,
                        (i & 2) ? halfExtents.y : -halfExtents.y,
                        (i & 4) ? halfExtents.z : -halfExtents.z,
                    ), transform);

                return Aabb.fromPoints(corners[]);
            }

            case ShapeKind.cylinder:
            {
                const half = height * 0.5f;
                Vector3f[8] corners;

                foreach(i; 0 .. 8)
                    corners[i] = transformPoint(Vector3f(
                        (i & 1) ? radius : -radius,
                        (i & 2) ? half : -half,
                        (i & 4) ? radius : -radius,
                    ), transform);

                return Aabb.fromPoints(corners[]);
            }

            case ShapeKind.convex:
            {
                Vector3f[] transformed;
                transformed.reserve(points.length);

                foreach(point; points)
                    transformed ~= transformPoint(point, transform);

                return Aabb.fromPoints(transformed);
            }

            case ShapeKind.triangleMesh:
            {
                Vector3f[] transformed;
                transformed.reserve(vertices.length);

                foreach(vertex; vertices)
                    transformed ~= transformPoint(vertex, transform);

                return Aabb.fromPoints(transformed);
            }

            case ShapeKind.plane:
                return Aabb(
                    Vector3f(float.nan, float.nan, float.nan),
                    Vector3f(float.nan, float.nan, float.nan),
                );
        }
    }
}

/// One collider in the world
struct Collider
{
    CollisionShape shape;
    Matrix4x4f transform = Matrix4x4f.identity;
    uint layer = 1;
    uint mask = 1;
    uint id;
    size_t node;
    bool kinematic;
}

Vector3f transformPoint(in Vector3f point, in Matrix4x4f transform)
{
    const result = Vector4f(point.x, point.y, point.z, 1) * transform;

    return Vector3f(result.x, result.y, result.z);
}

Vector3f transformDirection(in Vector3f direction, in Matrix4x4f transform)
{
    const result = Vector4f(direction.x, direction.y, direction.z, 0) * transform;

    return Vector3f(result.x, result.y, result.z);
}

/// Triangle of a mesh collider by index
void triangleVertices(
    in CollisionShape shape,
    size_t triangle,
    out Vector3f a,
    out Vector3f b,
    out Vector3f c,
)
{
    if(shape.indices.length)
    {
        const base = triangle * 3;
        a = shape.vertices[shape.indices[base]];
        b = shape.vertices[shape.indices[base + 1]];
        c = shape.vertices[shape.indices[base + 2]];
    }
    else
    {
        const base = triangle * 3;
        a = shape.vertices[base];
        b = shape.vertices[base + 1];
        c = shape.vertices[base + 2];
    }
}

size_t triangleCount(in CollisionShape shape)
{
    return shape.indices.length ? shape.indices.length / 3 : shape.vertices.length / 3;
}

unittest
{
    const box = Aabb(Vector3f(-1, -1, -1), Vector3f(1, 1, 1));

    assert(box.isValid());
    assert(box.center == Vector3f(0, 0, 0));
    assert(box.size == Vector3f(2, 2, 2));
    assert(box.contains(Vector3f(0, 0, 0)));
    assert(!box.contains(Vector3f(2, 0, 0)));
    assert(box.overlaps(Aabb(Vector3f(0, 0, 0), Vector3f(2, 2, 2))));
    assert(!box.overlaps(Aabb(Vector3f(2, 2, 2), Vector3f(3, 3, 3))));
    assert(box.swept(Vector3f(2, 0, 0)).contains(Vector3f(2, 0, 0)));

    const translated = box.unionWithPoint(Vector3f(3, 0, 0));
    assert(translated.min == Vector3f(-1, -1, -1));
    assert(translated.max == Vector3f(3, 1, 1));

    const capsule = CollisionShape.capsule(0.4f, 1.8f);
    assert(abs(capsule.capsuleHalfSegment() - 0.5f) < 1e-5f);

    const bounds = capsule.bounds(Matrix4x4f.identity);
    assert(abs(bounds.min.y + 0.9f) < 1e-5f);
    assert(abs(bounds.max.y - 0.9f) < 1e-5f);
    assert(abs(bounds.max.x - 0.4f) < 1e-5f);

    const shifted = CollisionShape.box(Vector3f(2, 2, 2))
        .bounds(Vector3f(0, 3, 0).translationMatrix);
    assert(shifted.min == Vector3f(-1, 2, -1));
    assert(shifted.max == Vector3f(1, 4, 1));
}
