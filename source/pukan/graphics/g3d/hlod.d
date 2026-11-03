module pukan.graphics.g3d.hlod;

import dlib.math: Matrix4x4f, Vector2f, Vector3f, Vector4f;
import pukan.graphics.common.misc: Boxf, expandAABB;
import pukan.graphics.g3d.mesh: mirrors;
import pukan.graphics.g3d.pbr.mesh: MeshGeometry;

/// One geometry of a proxy and where it stands in the cell
struct ProxyPiece
{
    /// Kept by the caller, which owns the pieces the cell loaded
    const(MeshGeometry)* geometry;
    Matrix4x4f transform;
}

/// Moves a direction by the rotation and scale of a transform
private Vector3f direction(in Vector3f value, in Matrix4x4f transform)
{
    const moved = Vector4f(value.x, value.y, value.z, 0) * transform;

    return Vector3f(moved.x, moved.y, moved.z);
}

/// Whether a piece can enter a proxy; a skinned one moves with its pose
private bool mergeable(in MeshGeometry geometry)
{
    return geometry.positions.length != 0
        && geometry.joints.length == 0
        && geometry.weights.length == 0;
}

/**
    Merges the pieces into one geometry in world space.

    A proxy stands for a whole cell: one draw where the cell needs many, at a
    distance where its detail is gone. Pieces that carry skinning stay out,
    because their vertices move with a pose and a merged copy cannot.

    An attribute survives only when some piece carries it; pieces without it
    take a default, so the merged buffers keep one layout.
*/
MeshGeometry mergeGeometry(scope const(ProxyPiece)[] pieces)
{
    MeshGeometry result;

    bool hasNormals;
    bool hasTangents;
    bool hasTexCoords;
    bool hasTexCoords1;
    bool hasColors;
    size_t vertices;
    size_t indices;

    foreach(piece; pieces)
    {
        const geometry = *piece.geometry;

        if(!geometry.mergeable)
            continue;

        const count = geometry.positions.length;

        vertices += count;
        indices += geometry.indices.length ? geometry.indices.length : count;

        hasNormals = hasNormals || geometry.normals.length != 0;
        hasTangents = hasTangents || geometry.tangents.length != 0;
        hasTexCoords = hasTexCoords || geometry.texCoords.length != 0;
        hasTexCoords1 = hasTexCoords1 || geometry.texCoords1.length != 0;
        hasColors = hasColors || geometry.colors.length != 0;
    }

    if(vertices == 0)
        return result;

    result.positions.length = vertices;
    result.indices.length = indices;

    if(hasNormals)
        result.normals.length = vertices;

    if(hasTangents)
        result.tangents.length = vertices;

    if(hasTexCoords)
        result.texCoords.length = vertices;

    if(hasTexCoords1)
        result.texCoords1.length = vertices;

    if(hasColors)
        result.colors.length = vertices;

    size_t vertexBase;
    size_t indexBase;
    bool started;

    foreach(piece; pieces)
    {
        const geometry = *piece.geometry;

        if(!geometry.mergeable)
            continue;

        const transform = piece.transform;
        const count = geometry.positions.length;
        const mirrored = transform.mirrors;
        const indexed = geometry.indices.length != 0;
        const indexCount = indexed ? geometry.indices.length : count;

        foreach(i; 0 .. count)
        {
            const moved = Vector4f(geometry.positions[i].x, geometry.positions[i].y, geometry.positions[i].z, 1)
                * transform;
            const world = Vector3f(moved.x, moved.y, moved.z);

            result.positions[vertexBase + i] = world;

            if(started)
                expandAABB(result.aabb, world);
            else
            {
                result.aabb = Boxf(world, world);
                started = true;
            }

            if(hasNormals)
                result.normals[vertexBase + i] = i < geometry.normals.length
                    ? direction(geometry.normals[i], transform).normalized
                    : Vector3f(0, 0, 0);

            if(hasTangents)
            {
                if(i < geometry.tangents.length)
                {
                    const tangent = geometry.tangents[i];
                    const axis = direction(Vector3f(tangent.x, tangent.y, tangent.z), transform).normalized;
                    const sign = mirrored ? -tangent.w : tangent.w;

                    result.tangents[vertexBase + i] = Vector4f(axis.x, axis.y, axis.z, sign);
                }
                else
                    result.tangents[vertexBase + i] = Vector4f(0, 0, 0, 1);
            }

            if(hasTexCoords)
                result.texCoords[vertexBase + i] = i < geometry.texCoords.length
                    ? geometry.texCoords[i]
                    : Vector2f(0, 0);

            if(hasTexCoords1)
                result.texCoords1[vertexBase + i] = i < geometry.texCoords1.length
                    ? geometry.texCoords1[i]
                    : Vector2f(0, 0);

            if(hasColors)
                result.colors[vertexBase + i] = i < geometry.colors.length
                    ? geometry.colors[i]
                    : 0xFFFFFFFF;
        }

        // A mirrored transform turns the triangles over, so their winding follows
        const flip = mirrored && indexCount % 3 == 0;

        foreach(i; 0 .. indexCount)
        {
            const index = indexed ? geometry.indices[i] : cast(uint) i;
            const local = i % 3;

            result.indices[indexBase + i] = cast(uint)(vertexBase + (flip ? index - local + 2 - local : index));
        }

        vertexBase += count;
        indexBase += indexCount;
    }

    return result;
}

unittest
{
    // Two quads merge into one geometry with their own vertices and indices
    MeshGeometry quad;
    quad.positions = [Vector3f(0, 0, 0), Vector3f(1, 0, 0), Vector3f(0, 1, 0), Vector3f(1, 1, 0)];
    quad.normals = [Vector3f(0, 0, 1), Vector3f(0, 0, 1), Vector3f(0, 0, 1), Vector3f(0, 0, 1)];
    quad.texCoords = [Vector2f(0, 0), Vector2f(1, 0), Vector2f(0, 1), Vector2f(1, 1)];
    quad.indices = [0u, 1u, 2u, 1u, 3u, 2u];
    quad.aabb = Boxf(Vector3f(0, 0, 0), Vector3f(1, 1, 0));

    auto moved = Matrix4x4f.identity;
    moved.a14 = 10;

    const merged = mergeGeometry([
        ProxyPiece(&quad, Matrix4x4f.identity),
        ProxyPiece(&quad, moved),
    ]);

    assert(merged.positions.length == 8);
    assert(merged.indices.length == 12);
    assert(merged.normals.length == 8);
    assert(merged.texCoords.length == 8);

    // The second quad keeps its own vertices, offset by its transform
    assert(merged.positions[4] == Vector3f(10, 0, 0));
    assert(merged.positions[5] == Vector3f(11, 0, 0));

    // Indices of the second piece point past the first four vertices
    assert(merged.indices[6 .. 12] == [4u, 5u, 6u, 5u, 7u, 6u]);

    assert(merged.aabb.min == Vector3f(0, 0, 0));
    assert(merged.aabb.max == Vector3f(11, 1, 0));
}

unittest
{
    // A mirrored piece keeps its faces towards the viewer: the winding flips
    MeshGeometry triangle;
    triangle.positions = [Vector3f(0, 0, 0), Vector3f(1, 0, 0), Vector3f(0, 1, 0)];
    triangle.indices = [0u, 1u, 2u];

    auto mirror = Matrix4x4f.identity;
    mirror.a11 = -1;

    const merged = mergeGeometry([ProxyPiece(&triangle, mirror)]);

    assert(merged.indices == [2u, 1u, 0u]);
    assert(merged.positions[1] == Vector3f(-1, 0, 0));
    assert(merged.aabb.min.x == -1);
}

unittest
{
    // A skinned piece cannot be merged, and an attribute only one piece carries
    // reaches the others as a default
    import pukan.graphics.g3d.pbr.mesh: Vector4us;

    MeshGeometry plain;
    plain.positions = [Vector3f(0, 0, 0), Vector3f(1, 0, 0), Vector3f(0, 1, 0)];
    plain.indices = [0u, 1u, 2u];

    MeshGeometry coloured = plain;
    coloured.colors = [0xFF00FF00, 0xFF00FF00, 0xFF00FF00];

    MeshGeometry skinned = plain;
    skinned.joints = [Vector4us(0, 0, 0, 0)];

    const merged = mergeGeometry([
        ProxyPiece(&plain, Matrix4x4f.identity),
        ProxyPiece(&skinned, Matrix4x4f.identity),
        ProxyPiece(&coloured, Matrix4x4f.identity),
    ]);

    // The skinned piece is left out, so two pieces land in the proxy
    assert(merged.positions.length == 6);
    assert(merged.indices.length == 6);
    assert(merged.colors.length == 6);
    assert(merged.colors[0] == 0xFFFFFFFF);
    assert(merged.colors[3] == 0xFF00FF00);
    assert(merged.normals.length == 0);
}
