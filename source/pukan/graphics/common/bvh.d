module pukan.graphics.common.bvh;

import dlib.math: Matrix4x4f, Vector3f;
import pukan.graphics.common.misc: Boxf, hasBounds, isVisible, mergeAabb;
import std.algorithm: sort;
import std.math: abs, isNaN;

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

/// Static bounding volume hierarchy over boxes, for culling and picking inside a cell
final class BoxBvh
{
    private struct Node
    {
        Boxf bounds;
        uint start;
        uint count;
        uint left;
        uint right;
    }

    private Node[] nodes;
    private uint[] order;
    private Boxf[] boxes;

    void build(in Boxf[] itemBoxes)
    {
        boxes = itemBoxes.dup;
        order.length = boxes.length;

        foreach(i; 0 .. order.length)
            order[i] = cast(uint) i;

        nodes = null;

        if(order.length)
            buildNode(0, cast(uint) order.length);
    }

    /// Visits every box that is visible under `mvp`
    void queryVisible(in Matrix4x4f mvp, scope void delegate(size_t item) visit) const
    {
        if(nodes.length)
            visibleNode(0, mvp, visit);
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

        if(nodes.length)
            raycastNode(0, origin, direction, maxT, hit, item, distance);

        return hit;
    }

    private uint buildNode(uint start, uint count)
    {
        const index = cast(uint) nodes.length;
        nodes ~= Node();

        Boxf nodeBounds;
        Vector3f first;
        Vector3f last;

        foreach(i; start .. start + count)
        {
            const box = boxes[order[i]];
            mergeAabb(nodeBounds, box);

            const center = (box.min + box.max) * 0.5f;

            if(i == start)
            {
                first = center;
                last = center;
                continue;
            }

            foreach(axis; 0 .. 3)
            {
                if(center[axis] < first[axis])
                    first[axis] = center[axis];
                else
                if(center[axis] > last[axis])
                    last[axis] = center[axis];
            }
        }

        nodes[index].bounds = nodeBounds;

        if(count <= 4)
        {
            nodes[index].start = start;
            nodes[index].count = count;
            return index;
        }

        const extent = last - first;
        const axis = extent.x > extent.y
            ? (extent.x > extent.z ? 0 : 2)
            : (extent.y > extent.z ? 1 : 2);

        order[start .. start + count].sort!((a, b) =>
            (boxes[a].min[axis] + boxes[a].max[axis]) < (boxes[b].min[axis] + boxes[b].max[axis]));

        const middle = start + count / 2;
        const left = buildNode(start, middle - start);
        const right = buildNode(middle, start + count - middle);

        nodes[index].left = left;
        nodes[index].right = right;

        return index;
    }

    private void visibleNode(uint index, in Matrix4x4f mvp, scope void delegate(size_t) visit) const
    {
        const node = nodes[index];

        if(!isVisible(node.bounds, mvp))
            return;

        if(node.count)
        {
            // A visible leaf can still hold a box the frustum misses
            foreach(i; node.start .. node.start + node.count)
                if(isVisible(boxes[order[i]], mvp))
                    visit(order[i]);

            return;
        }

        visibleNode(node.left, mvp, visit);
        visibleNode(node.right, mvp, visit);
    }

    private void raycastNode(
        uint index,
        in Vector3f origin,
        in Vector3f direction,
        float maxT,
        ref bool hit,
        ref size_t item,
        ref float distance,
    ) const
    {
        const node = nodes[index];
        const entry = rayBox(node.bounds, origin, direction, maxT);

        if(entry.isNaN || (hit && entry > distance))
            return;

        if(node.count)
        {
            foreach(i; node.start .. node.start + node.count)
            {
                const t = rayBox(boxes[order[i]], origin, direction, maxT);

                if(t.isNaN || (hit && t > distance))
                    continue;

                hit = true;
                item = order[i];
                distance = t;
            }

            return;
        }

        raycastNode(node.left, origin, direction, maxT, hit, item, distance);
        raycastNode(node.right, origin, direction, maxT, hit, item, distance);
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
