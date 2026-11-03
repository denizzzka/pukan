module pukan.physics.bvh;

import dlib.math: Vector3f;
import bvh = pukan.bvh;
import pukan.physics.narrowphase: rayAabb;
import pukan.physics.shapes: Aabb;

/// Boxes of the collision world, as the hierarchy build and its traversals read them
private struct AabbOps
{
    static void merge(ref Aabb into, in Aabb box)
    {
        into = into.unionWith(box);
    }

    static Vector3f center(in Aabb box)
    {
        return box.center;
    }

    static float rayT(in Aabb box, in Vector3f origin, in Vector3f direction, float maxT)
    {
        float t;

        return rayAabb(box, origin, direction, maxT, t) ? t : float.nan;
    }
}

/**
    Static bounding volume hierarchy over primitive bounds: nested boxes let a
    ray or a swept capsule skip most primitives. Built once after the level loads.
*/
final class Bvh : bvh.Bvh!(Aabb, AabbOps)
{
    /// Visits every primitive whose bounds overlap `box`
    void query(in Aabb box, scope void delegate(size_t primitive) visit) const
    {
        super.query((in Aabb bounds) => bounds.overlaps(box), visit);
    }

    /// Visits every primitive whose bounds the ray enters within `maxT`
    void raycast(
        in Vector3f origin,
        in Vector3f direction,
        float maxT,
        scope void delegate(size_t primitive) visit,
    ) const
    {
        super.raycast(origin, direction, maxT, (primitive, distance) => visit(primitive));
    }
}

unittest
{
    Aabb[] boxes;

    foreach(i; 0 .. 10)
    {
        const center = Vector3f(cast(float) (i * 2), 0, 0);
        boxes ~= Aabb(center - Vector3f(1, 1, 1), center + Vector3f(1, 1, 1));
    }

    auto bvh = new Bvh;
    bvh.build(boxes);

    const queryBox = Aabb(Vector3f(-0.5f, -0.5f, -0.5f), Vector3f(4.5f, 0.5f, 0.5f));

    size_t[] found;
    bvh.query(queryBox, (primitive) {
        if(boxes[primitive].overlaps(queryBox))
            found ~= primitive;
    });
    assert(found.length == 3);

    found = null;
    bvh.raycast(Vector3f(-5, 0, 0), Vector3f(1, 0, 0), 100, (primitive) {
        found ~= primitive;
    });
    assert(found.length == 10);

    found = null;
    bvh.raycast(Vector3f(-5, 10, 0), Vector3f(1, 0, 0), 100, (primitive) {
        found ~= primitive;
    });
    assert(found.length == 0);
}
