module pukan.physics.world;

import dlib.math: Matrix4x4f, Vector3f, dot, translationMatrix;
import pukan.physics.bvh: Bvh;
import pukan.physics.narrowphase:
    rayAabb,
    raySphere,
    rayTriangle,
    segmentAabbDistanceSquared,
    sweepCapsuleBox,
    sweepCapsuleSphere,
    sweepCapsuleTriangle;
import pukan.physics.shapes:
    Aabb,
    Collider,
    CollisionShape,
    ShapeKind,
    transformDirection,
    transformPoint,
    triangleCount,
    triangleVertices;
import std.algorithm: min;
import std.math: abs, sqrt;

private struct Primitive
{
    uint collider;
    uint triangle = uint.max;
}

/// Closest ray result
struct RayHit
{
    bool hit;
    float t;
    Vector3f point;
    Vector3f normal;
    uint collider;
    size_t node;
}

/// Earliest capsule sweep result
struct ShapeCastHit
{
    bool hit;
    float fraction;
    Vector3f point;
    Vector3f normal;
    uint collider;
    size_t node;
}

/// Static collision world with a BVH over primitives and mesh triangles
final class CollisionWorld
{
    private Collider[] colliders;
    private Primitive[] primitives;
    private Aabb[] primitiveBounds;
    private Bvh bvh;
    private uint[] planeColliders;

    uint add(Collider collider)
    {
        collider.id = cast(uint) colliders.length;
        colliders ~= collider;

        return collider.id;
    }

    void clear()
    {
        colliders = null;
        primitives = null;
        primitiveBounds = null;
        planeColliders = null;
        bvh = null;
    }

    void build()
    {
        primitives = null;
        primitiveBounds = null;
        planeColliders = null;

        foreach(index, ref collider; colliders)
        {
            switch(collider.shape.kind)
            {
                case ShapeKind.none:
                    break;

                case ShapeKind.plane:
                    planeColliders ~= cast(uint) index;
                    break;

                case ShapeKind.triangleMesh:
                    foreach(triangle; 0 .. triangleCount(collider.shape))
                    {
                        Vector3f a;
                        Vector3f b;
                        Vector3f c;
                        triangleVertices(collider.shape, triangle, a, b, c);

                        const wa = transformPoint(a, collider.transform);
                        const wb = transformPoint(b, collider.transform);
                        const wc = transformPoint(c, collider.transform);

                        primitives ~= Primitive(cast(uint) index, cast(uint) triangle);
                        primitiveBounds ~= Aabb.fromPoints([wa, wb, wc]);
                    }
                    break;

                default:
                    primitives ~= Primitive(cast(uint) index, uint.max);
                    primitiveBounds ~= collider.shape.bounds(collider.transform);
                    break;
            }
        }

        bvh = new Bvh;
        bvh.build(primitiveBounds);
    }

    size_t colliderCount() const
    {
        return colliders.length;
    }

    const(Collider)[] allColliders() const
    {
        return colliders;
    }

    /// Closest ray hit against every collider whose layer matches `mask`
    RayHit raycast(
        in Vector3f origin,
        in Vector3f direction,
        float maxDistance = float.infinity,
        uint mask = uint.max,
    ) const
    {
        RayHit best;
        best.t = maxDistance;

        if(bvh !is null)
        {
            bvh.raycast(origin, direction, maxDistance, (primitiveIndex) {
                const primitive = primitives[primitiveIndex];
                const collider = colliders[primitive.collider];

                if((collider.layer & mask) == 0)
                    return;

                RayHit hit;

                if(rayPrimitive(primitive, collider, origin, direction, maxDistance, hit)
                    && hit.t < best.t)
                    best = hit;
            });
        }

        foreach(index; planeColliders)
        {
            const collider = colliders[index];

            if((collider.layer & mask) == 0)
                continue;

            RayHit hit;

            if(rayPlane(collider, origin, direction, maxDistance, hit) && hit.t < best.t)
                best = hit;
        }

        best.hit = best.t < maxDistance;

        return best;
    }

    /// True when a capsule already overlaps any collider matching `mask`
    bool overlapCapsule(
        in Vector3f a,
        in Vector3f b,
        float radius,
        uint mask = uint.max,
        float margin = 0.001f,
        out ShapeCastHit hit,
    ) const
    {
        hit = sweepCapsule(a, b, radius, Vector3f(0, 0, 0), mask, margin);

        return hit.hit;
    }

    /// Earliest hit of a moving capsule segment
    ShapeCastHit sweepCapsule(
        in Vector3f a,
        in Vector3f b,
        float radius,
        in Vector3f motion,
        uint mask = uint.max,
        float margin = 0.001f,
    ) const
    {
        ShapeCastHit best;
        best.fraction = 1.0f;

        const swept = Aabb.fromPoints([a, b])
            .unionWith(Aabb.fromPoints([a + motion, b + motion]))
            .expanded(radius + margin);

        if(bvh !is null)
        {
            bvh.query(swept, (primitiveIndex) {
                const primitive = primitives[primitiveIndex];
                const collider = colliders[primitive.collider];

                if((collider.layer & mask) == 0)
                    return;

                float fraction;
                Vector3f point;
                Vector3f normal;
                bool hit;

                if(primitive.triangle != uint.max)
                {
                    Vector3f ta;
                    Vector3f tb;
                    Vector3f tc;
                    triangleVertices(collider.shape, primitive.triangle, ta, tb, tc);

                    hit = sweepCapsuleTriangle(
                        a, b, radius, motion,
                        transformPoint(ta, collider.transform),
                        transformPoint(tb, collider.transform),
                        transformPoint(tc, collider.transform),
                        margin, fraction, point, normal);
                }
                else
                {
                    switch(collider.shape.kind)
                    {
                        case ShapeKind.box:
                            hit = sweepCapsuleBox(
                                a, b, radius, motion,
                                collider.transform, collider.shape.halfExtents,
                                margin, fraction, point, normal);
                            break;

                        case ShapeKind.sphere:
                        {
                            const center = Vector3f(
                                collider.transform.a14,
                                collider.transform.a24,
                                collider.transform.a34,
                            );

                            hit = sweepCapsuleSphere(
                                a, b, radius, center, collider.shape.radius,
                                motion, margin, fraction, point, normal);
                            break;
                        }

                        default:
                            hit = false;
                            break;
                    }
                }

                if(hit && fraction < best.fraction)
                {
                    best.hit = true;
                    best.fraction = fraction;
                    best.point = point;
                    best.normal = normal;
                    best.collider = collider.id;
                    best.node = collider.node;
                }
            });
        }

        foreach(index; planeColliders)
        {
            const collider = colliders[index];

            if((collider.layer & mask) == 0)
                continue;

            float fraction;
            Vector3f point;
            Vector3f normal;

            if(sweepCapsulePlane(collider, a, b, radius, motion, margin, fraction, point, normal)
                && fraction < best.fraction)
            {
                best.hit = true;
                best.fraction = fraction;
                best.point = point;
                best.normal = normal;
                best.collider = collider.id;
                best.node = collider.node;
            }
        }

        return best;
    }

    private static bool rayPrimitive(
        in Primitive primitive,
        in Collider collider,
        in Vector3f origin,
        in Vector3f direction,
        float maxDistance,
        out RayHit hit,
    )
    {
        if(primitive.triangle != uint.max)
        {
            Vector3f a;
            Vector3f b;
            Vector3f c;
            triangleVertices(collider.shape, primitive.triangle, a, b, c);

            float t;
            Vector3f normal;

            if(!rayTriangle(
                origin, direction,
                transformPoint(a, collider.transform),
                transformPoint(b, collider.transform),
                transformPoint(c, collider.transform),
                maxDistance, t, normal))
                return false;

            hit = RayHit(true, t, origin + direction * t, normal, collider.id, collider.node);
            return true;
        }

        switch(collider.shape.kind)
        {
            case ShapeKind.sphere:
            {
                const center = Vector3f(
                    collider.transform.a14,
                    collider.transform.a24,
                    collider.transform.a34,
                );
                float t;

                if(!raySphere(center, collider.shape.radius, origin, direction, maxDistance, t))
                    return false;

                const point = origin + direction * t;
                hit = RayHit(true, t, point, (point - center).normalized, collider.id, collider.node);
                return true;
            }

            case ShapeKind.box:
                return rayBox(collider, origin, direction, maxDistance, hit);

            case ShapeKind.plane:
                return rayPlane(collider, origin, direction, maxDistance, hit);

            default:
                return false;
        }
    }

    private static bool rayBox(
        in Collider collider,
        in Vector3f origin,
        in Vector3f direction,
        float maxDistance,
        out RayHit hit,
    )
    {
        const inverse = collider.transform.inverse;
        const localOrigin = transformPoint(origin, inverse);
        const localDirection = transformDirection(direction, inverse);
        const half = collider.shape.halfExtents;
        const box = Aabb(-half, half);
        float t;

        if(!rayAabb(box, localOrigin, localDirection, maxDistance, t))
            return false;

        const localPoint = localOrigin + localDirection * t;
        Vector3f localNormal;
        const epsilon = 1e-4f;

        if(abs(localPoint.x - half.x) < epsilon)
            localNormal = Vector3f(1, 0, 0);
        else if(abs(localPoint.x + half.x) < epsilon)
            localNormal = Vector3f(-1, 0, 0);
        else if(abs(localPoint.y - half.y) < epsilon)
            localNormal = Vector3f(0, 1, 0);
        else if(abs(localPoint.y + half.y) < epsilon)
            localNormal = Vector3f(0, -1, 0);
        else if(abs(localPoint.z - half.z) < epsilon)
            localNormal = Vector3f(0, 0, 1);
        else
            localNormal = Vector3f(0, 0, -1);

        hit = RayHit(
            true,
            t,
            transformPoint(localPoint, collider.transform),
            transformDirection(localNormal, collider.transform).normalized,
            collider.id,
            collider.node,
        );

        return true;
    }

    private static bool rayPlane(
        in Collider collider,
        in Vector3f origin,
        in Vector3f direction,
        float maxDistance,
        out RayHit hit,
    )
    {
        const normal = collider.shape.planeNormal.normalized;
        const denominator = dot(direction, normal);

        if(abs(denominator) < 1e-8f)
            return false;

        const t = (collider.shape.planeDistance - dot(origin, normal)) / denominator;

        if(t < 0.0f || t > maxDistance)
            return false;

        hit = RayHit(true, t, origin + direction * t, normal, collider.id, collider.node);

        return true;
    }

    private static bool sweepCapsulePlane(
        in Collider collider,
        in Vector3f a,
        in Vector3f b,
        float radius,
        in Vector3f motion,
        float margin,
        out float fraction,
        out Vector3f point,
        out Vector3f normal,
    )
    {
        const planeNormal = collider.shape.planeNormal.normalized;
        const distanceA = dot(a, planeNormal) - collider.shape.planeDistance;
        const distanceB = dot(b, planeNormal) - collider.shape.planeDistance;
        const distance = min(distanceA, distanceB);
        const closing = dot(motion, planeNormal);

        if(closing >= 0.0f)
            return false;

        const gap = distance - radius - margin;

        if(gap > 0.0f)
        {
            fraction = gap / -closing;
        }
        else
            fraction = 0.0f;

        if(fraction > 1.0f)
            return false;

        normal = planeNormal;
        point = (distanceA < distanceB ? a : b) + motion * fraction - planeNormal * radius;

        return true;
    }
}

unittest
{
    auto world = new CollisionWorld;

    world.add(Collider(
        CollisionShape.box(Vector3f(20, 1, 20)),
        Vector3f(0, -0.5f, 0).translationMatrix,
    ));

    world.add(Collider(
        CollisionShape.box(Vector3f(2, 4, 20)),
        Vector3f(5, 2, 0).translationMatrix,
    ));

    world.build();

    const ray = world.raycast(Vector3f(0, 5, 0), Vector3f(0, -1, 0));
    assert(ray.hit);
    assert(abs(ray.t - 5.0f) < 1e-4f);
    assert(ray.normal.y > 0.9f);

    const wallRay = world.raycast(Vector3f(0, 1, 0), Vector3f(1, 0, 0));
    assert(wallRay.hit);
    assert(abs(wallRay.t - 4.0f) < 1e-4f);
    assert(wallRay.normal.x < -0.9f);

    const down = world.sweepCapsule(
        Vector3f(0, 0.4f, 0), Vector3f(0, 1.4f, 0), 0.4f,
        Vector3f(0, -0.05f, 0));

    assert(down.hit);
    assert(down.fraction < 0.2f);
    assert(down.normal.y > 0.9f);

    const inverse = Vector3f(5, 2, 0).translationMatrix.inverse;
    const localPoint = transformPoint(Vector3f(3, 0.5f, 0), inverse);

    assert(abs(localPoint.x + 2) < 1e-4f);
    assert(abs(localPoint.y + 1.5f) < 1e-4f);

    Vector3f localA;
    Vector3f localB;
    const localDistance = segmentAabbDistanceSquared(
        Vector3f(-2, -1.5f, 0), Vector3f(-2, -0.5f, 0),
        Vector3f(1, 2, 10), localA, localB);

    assert(abs(sqrt(localDistance) - 1.0f) < 1e-4f);

    const midDistance = segmentAabbDistanceSquared(
        Vector3f(-1.401f, -1.5f, 0), Vector3f(-1.401f, -0.5f, 0),
        Vector3f(1, 2, 10), localA, localB);

    assert(abs(sqrt(midDistance) - 0.401f) < 1e-4f);

    float directFraction;
    Vector3f directPoint;
    Vector3f directNormal;

    assert(sweepCapsuleBox(
        Vector3f(3, 0.5f, 0), Vector3f(3, 1.5f, 0), 0.4f, Vector3f(2, 0, 0),
        Vector3f(5, 2, 0).translationMatrix, Vector3f(1, 2, 10),
        0.001f, directFraction, directPoint, directNormal));

    const intoWall = world.sweepCapsule(
        Vector3f(3, 0.5f, 0), Vector3f(3, 1.5f, 0), 0.4f,
        Vector3f(2, 0, 0));

    assert(intoWall.hit);
    assert(intoWall.normal.x < -0.9f);

    ShapeCastHit overlap;
    assert(world.overlapCapsule(Vector3f(0, 0.4f, 0), Vector3f(0, 1.4f, 0), 0.4f,
        uint.max, 0.001f, overlap));
    assert(!world.overlapCapsule(Vector3f(0, 5, 0), Vector3f(0, 6, 0), 0.4f,
        uint.max, 0.001f, overlap));
}
