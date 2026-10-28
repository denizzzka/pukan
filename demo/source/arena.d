module arena;

import dlib.math;
import pukan.gltf: GlTF;
import pukan.primitives_tree: Bone;
import std.algorithm: max, min, sort;
import std.format: format;
import std.math: atan2, lrint, sqrt;

/// Places the objects at the nodes of an icosahedron, largest first.
///
/// The first node faces the camera, the next one is its opposite, and every
/// following node is the farthest from the ones taken, which spreads the sizes.
/// The icosahedron grows until neighbouring objects stop intersecting.
void placeOnIcosahedron(Node)(ref Node node, GlTF[] objects, float targetSize = 0.1f)
{
    if(objects.length == 0)
        return;

    struct Item
    {
        GlTF object;
        Vector3f center;
        float extent;
    }

    Item[] items;
    items.reserve(objects.length);

    foreach(object; objects)
    {
        const aabb = object.calcAABB;
        const size = aabb.max - aabb.min;

        items ~= Item(object, aabb.min + size / 2, size.length);
    }

    items.sort!((a, b) => a.extent > b.extent);

    const nodes = spreadOrder(icosahedronNodes(items.length));

    // Equal on-screen sizes, so every object needs the same radius. The accessor
    // bounds ignore node transforms, hence the margin.
    const float objectRadius = targetSize / 2 * 1.3f;

    float arenaRadius = targetSize;

    foreach(i; 0 .. nodes.length)
        foreach(j; i + 1 .. nodes.length)
            arenaRadius = max(arenaRadius, 2 * objectRadius / (nodes[i] - nodes[j]).length);

    foreach(i, item; items)
    {
        // A lone object faces the camera instead of the first icosahedron node
        const direction = items.length == 1 ? Vector3f(0, 0, -1) : nodes[i];
        const position = direction * arenaRadius;

        // The glTF front is +Z, which the loader mirrors to -Z
        const flat = Vector3f(direction.x, 0, direction.z);
        const float yaw = flat.length > 1e-6f ? atan2(flat.x, -flat.z) : 0;

        auto trans = Matrix4x4f.identity;
        trans *= position.translationMatrix;
        trans *= rotationMatrix!float(Axis.y, yaw);
        trans *= (Vector3f(1, 1, 1) * (targetSize / item.extent)).scaleMatrix;
        trans *= (-item.center).translationMatrix;

        node
            .addChild(Bone(mat: trans))
            .addChild(item.object);
    }
}

/// Orders the nodes so that every next one is as far as possible from the taken
private Vector3f[] spreadOrder(Vector3f[] nodes)
{
    if(nodes.length < 2)
        return nodes;

    size_t first;
    float frontMost = -float.infinity;

    foreach(i, node; nodes)
        if(-node.z > frontMost)
        {
            frontMost = -node.z;
            first = i;
        }

    bool[] taken;
    taken.length = nodes.length;

    float[] nearest;
    nearest.length = nodes.length;
    nearest[] = float.infinity;

    Vector3f[] ordered;
    ordered.reserve(nodes.length);

    size_t current = first;

    foreach(_; 0 .. nodes.length)
    {
        taken[current] = true;
        ordered ~= nodes[current];

        foreach(i, node; nodes)
            nearest[i] = min(nearest[i], (node - nodes[current]).length);

        size_t next = size_t.max;
        float farthest = -1;

        foreach(i, node; nodes)
            if(!taken[i] && nearest[i] > farthest)
            {
                farthest = nearest[i];
                next = i;
            }

        if(next == size_t.max)
            break;

        current = next;
    }

    return ordered;
}

/// Geodesic icosahedron, subdivided until it has at least `minCount` nodes
private Vector3f[] icosahedronNodes(size_t minCount)
{
    const float phi = (1.0f + sqrt(5.0f)) / 2.0f;

    Vector3f[] vertices = [
        Vector3f(-1, phi, 0), Vector3f(1, phi, 0),
        Vector3f(-1, -phi, 0), Vector3f(1, -phi, 0),
        Vector3f(0, -1, phi), Vector3f(0, 1, phi),
        Vector3f(0, -1, -phi), Vector3f(0, 1, -phi),
        Vector3f(phi, 0, -1), Vector3f(phi, 0, 1),
        Vector3f(-phi, 0, -1), Vector3f(-phi, 0, 1),
    ];

    foreach(ref vertex; vertices)
        vertex = vertex.normalized;

    uint[3][] faces = [
        [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
        [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
        [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
        [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
    ];

    while(vertices.length < minCount)
    {
        Vector3f[] added;
        size_t[string] indexOf;

        uint midpointOf(uint a, uint b)
        {
            const midpoint = ((vertices[a] + vertices[b]) / 2).normalized;
            const key = format("%d,%d,%d", lrint(midpoint.x * 1_000_000),
                lrint(midpoint.y * 1_000_000), lrint(midpoint.z * 1_000_000));

            if(auto index = key in indexOf)
                return cast(uint) *index;

            const index = cast(uint) (vertices.length + added.length);
            added ~= midpoint;
            indexOf[key] = index;

            return index;
        }

        uint[3][] subdivided;

        foreach(face; faces)
        {
            const ab = midpointOf(face[0], face[1]);
            const bc = midpointOf(face[1], face[2]);
            const ca = midpointOf(face[2], face[0]);

            subdivided ~= [face[0], ab, ca];
            subdivided ~= [face[1], bc, ab];
            subdivided ~= [face[2], ca, bc];
            subdivided ~= [ab, bc, ca];
        }

        vertices ~= added;
        faces = subdivided;
    }

    return vertices;
}
