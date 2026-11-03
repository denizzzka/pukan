module pukan.bvh;

import dlib.math: Vector3f;
import std.algorithm: sort;
import std.math: isNaN;

/**
    Static bounding volume hierarchy over boxes of type `B`.

    `Ops` supplies the few operations the build and the traversals need:
    `void merge(ref B into, in B box)`, `Vector3f center(in B box)` and
    `float rayT(in B box, in Vector3f origin, in Vector3f direction, float maxT)`,
    which returns the entry distance or NaN when the ray misses.
*/
class Bvh(B, Ops)
{
    private struct Node
    {
        B bounds;
        uint start;
        uint count;
        uint left;
        uint right;
    }

    private Node[] nodes;
    private uint[] order;
    private B[] boxes;

    void build(in B[] itemBoxes)
    {
        boxes = itemBoxes.dup;
        order.length = boxes.length;

        foreach(i; 0 .. order.length)
            order[i] = cast(uint) i;

        nodes = null;

        if(order.length)
            buildNode(0, cast(uint) order.length);
    }

    /// Visits every item whose box passes `hit`
    void query(scope bool delegate(in B box) hit, scope void delegate(size_t item) visit) const
    {
        if(nodes.length)
            queryNode(0, hit, visit);
    }

    /// Visits every item whose box the ray enters within `maxT`, with its entry distance
    void raycast(
        in Vector3f origin,
        in Vector3f direction,
        float maxT,
        scope void delegate(size_t item, float distance) visit,
    ) const
    {
        if(nodes.length)
            raycastNode(0, origin, direction, maxT, visit);
    }

    private uint buildNode(uint start, uint count)
    {
        const index = cast(uint) nodes.length;
        nodes ~= Node();

        B nodeBounds;
        Vector3f first;
        Vector3f last;

        foreach(i; start .. start + count)
        {
            const box = boxes[order[i]];
            Ops.merge(nodeBounds, box);

            const center = Ops.center(box);

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
            Ops.center(boxes[a])[axis] < Ops.center(boxes[b])[axis]);

        const middle = start + count / 2;
        const left = buildNode(start, middle - start);
        const right = buildNode(middle, start + count - middle);

        nodes[index].left = left;
        nodes[index].right = right;

        return index;
    }

    private void queryNode(
        uint index,
        scope bool delegate(in B box) hit,
        scope void delegate(size_t item) visit,
    ) const
    {
        const node = nodes[index];

        if(!hit(node.bounds))
            return;

        if(node.count)
        {
            // A node that passes can still hold a box that does not
            foreach(i; node.start .. node.start + node.count)
                if(hit(boxes[order[i]]))
                    visit(order[i]);

            return;
        }

        queryNode(node.left, hit, visit);
        queryNode(node.right, hit, visit);
    }

    private void raycastNode(
        uint index,
        in Vector3f origin,
        in Vector3f direction,
        float maxT,
        scope void delegate(size_t item, float distance) visit,
    ) const
    {
        const node = nodes[index];

        if(Ops.rayT(node.bounds, origin, direction, maxT).isNaN)
            return;

        if(node.count)
        {
            foreach(i; node.start .. node.start + node.count)
            {
                const t = Ops.rayT(boxes[order[i]], origin, direction, maxT);

                if(!t.isNaN)
                    visit(order[i], t);
            }

            return;
        }

        raycastNode(node.left, origin, direction, maxT, visit);
        raycastNode(node.right, origin, direction, maxT, visit);
    }
}
