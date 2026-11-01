module pukan.physics.bvh;

import dlib.math: Vector3f;
import pukan.physics.narrowphase: rayAabb;
import pukan.physics.shapes: Aabb;
import std.algorithm: sort;

private struct BvhNode
{
    Aabb bounds;
    uint start;
    uint count;
    uint left;
    uint right;
}

/// Static bounding volume hierarchy over primitive bounds
final class Bvh
{
    private BvhNode[] nodes;
    private uint[] order;
    private Aabb[] bounds;

    void build(Aabb[] primitiveBounds)
    {
        bounds = primitiveBounds;
        order.length = primitiveBounds.length;

        foreach(i; 0 .. order.length)
            order[i] = cast(uint) i;

        nodes = null;

        if(order.length)
            buildNode(0, cast(uint) order.length);
    }

    /// Visits every primitive whose bounds overlap `box`
    void query(in Aabb box, scope void delegate(uint primitive) visit) const
    {
        if(nodes.length)
            queryNode(0, box, visit);
    }

    /// Visits every primitive whose bounds the ray enters within `maxT`
    void raycast(
        in Vector3f origin,
        in Vector3f direction,
        float maxT,
        scope void delegate(uint primitive) visit,
    ) const
    {
        if(nodes.length)
            raycastNode(0, origin, direction, maxT, visit);
    }

    private uint buildNode(uint start, uint count)
    {
        const index = cast(uint) nodes.length;
        nodes ~= BvhNode();

        Aabb nodeBounds;
        Aabb centroids;

        foreach(i; start .. start + count)
        {
            const primitive = order[i];
            nodeBounds = nodeBounds.unionWith(bounds[primitive]);
            centroids = centroids.unionWithPoint(bounds[primitive].center);
        }

        nodes[index].bounds = nodeBounds;

        if(count <= 4)
        {
            nodes[index].start = start;
            nodes[index].count = count;
            return index;
        }

        const extent = centroids.size;
        const axis = extent.x > extent.y
            ? (extent.x > extent.z ? 0 : 2)
            : (extent.y > extent.z ? 1 : 2);

        order[start .. start + count].sort!((a, b) =>
            bounds[a].center[axis] < bounds[b].center[axis]);

        const middle = start + count / 2;
        const left = buildNode(start, middle - start);
        const right = buildNode(middle, start + count - middle);

        nodes[index].left = left;
        nodes[index].right = right;

        return index;
    }

    private void queryNode(uint index, in Aabb box, scope void delegate(uint) visit) const
    {
        const node = nodes[index];

        if(!node.bounds.overlaps(box))
            return;

        if(node.count)
        {
            foreach(i; node.start .. node.start + node.count)
                visit(order[i]);

            return;
        }

        queryNode(node.left, box, visit);
        queryNode(node.right, box, visit);
    }

    private void raycastNode(
        uint index,
        in Vector3f origin,
        in Vector3f direction,
        float maxT,
        scope void delegate(uint) visit,
    ) const
    {
        const node = nodes[index];
        float t;

        if(!rayAabb(node.bounds, origin, direction, maxT, t))
            return;

        if(node.count)
        {
            foreach(i; node.start .. node.start + node.count)
                visit(order[i]);

            return;
        }

        raycastNode(node.left, origin, direction, maxT, visit);
        raycastNode(node.right, origin, direction, maxT, visit);
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

    uint[] found;
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
