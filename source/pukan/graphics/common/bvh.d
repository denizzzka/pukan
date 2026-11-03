module pukan.graphics.common.bvh;

import dlib.math: Matrix4x4f, Vector3f;
import bvh = pukan.bvh;
import pukan.graphics.common.misc: Boxf, isVisible, mergeAabb;
import std.math: abs;

/// Distance along the ray to the box, NaN when the ray misses it
float rayBox(in Boxf box, in Vector3f origin, in Vector3f direction, float maxT)
{
    float near = 0;
    float far = maxT;

    foreach(axis; 0 .. 3)
    {
        const o = origin[axis];
        const d = direction[axis];

        if(abs(d) < 1e-8f)
        {
            if(o < box.min[axis] || o > box.max[axis])
                return float.nan;

            continue;
        }

        float t1 = (box.min[axis] - o) / d;
        float t2 = (box.max[axis] - o) / d;

        if(t1 > t2)
        {
            const swap = t1;
            t1 = t2;
            t2 = swap;
        }

        if(t1 > near)
            near = t1;

        if(t2 < far)
            far = t2;

        if(near > far)
            return float.nan;
    }

    return near;
}

/// Boxes of a cell, as the hierarchy build and its traversals read them
private struct BoxOps
{
    static void merge(ref Boxf into, in Boxf box)
    {
        mergeAabb(into, box);
    }

    static Vector3f center(in Boxf box)
    {
        return (box.min + box.max) * 0.5f;
    }

    static float rayT(in Boxf box, in Vector3f origin, in Vector3f direction, float maxT)
    {
        return rayBox(box, origin, direction, maxT);
    }
}

/// Static bounding volume hierarchy over boxes, for culling and picking inside a cell
final class BoxBvh : bvh.Bvh!(Boxf, BoxOps)
{
    /// Visits every box that is visible under `mvp`
    void queryVisible(in Matrix4x4f mvp, scope void delegate(size_t item) visit) const
    {
        super.query((in Boxf box) => isVisible(box, mvp), visit);
    }

    /// Nearest box the ray enters within `maxT`
    bool raycast(
        in Vector3f origin,
        in Vector3f direction,
        float maxT,
        out size_t item,
        out float distance,
    ) const
    {
        bool hit;

        super.raycast(origin, direction, maxT, (candidate, t) {
            if(hit && t > distance)
                return;

            hit = true;
            item = candidate;
            distance = t;
        });

        return hit;
    }
}

unittest
{
    import dlib.math: scaleMatrix;
    import std.math: isClose;

    Boxf at(float x) => Boxf(Vector3f(x, 0, 0), Vector3f(x + 1, 1, 1));

    auto bvh = new BoxBvh;
    bvh.build([at(0), at(2), at(10)]);

    // A frustum that covers the first two boxes but not the far one
    const view = Vector3f(0.2f, 0.2f, 0.2f).scaleMatrix;

    bool[size_t] seen;
    bvh.queryVisible(view, (item) { seen[item] = true; });

    assert(0 in seen && 1 in seen);
    assert(2 !in seen, "the far box is culled");

    // A ray along X meets the nearest box first
    size_t item;
    float t;

    assert(bvh.raycast(Vector3f(-5, 0.5f, 0.5f), Vector3f(1, 0, 0), 100, item, t));
    assert(item == 0 && isClose(t, 5, 1e-5f, 1e-5f));

    assert(!bvh.raycast(Vector3f(-5, 5, 5), Vector3f(1, 0, 0), 100, item, t),
        "a ray that misses every box reports no hit");
}
