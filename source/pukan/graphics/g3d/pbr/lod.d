module pukan.graphics.g3d.pbr.lod;

import dlib.math: Matrix4x4f, Vector3f;
import pukan.graphics.common.misc: Boxf, expandAABB, hasBounds;
import std.array: appender;
import std.math: floor, isNaN, sqrt;

/// Screen-space error a level may show, in pixels
enum lodTargetPixels = 8.0f;

/// Height of the viewport being recorded, in pixels; `Scene` installs it
float currentViewportHeight = 600.0f;

/// One coarser index list, built by merging vertices that share a grid cell
struct GeneratedLevel
{
    uint[] indices;
    /// Grid cell size of the level, in mesh units
    float error;
}

/**
    Builds coarser index lists by clustering the vertices of `indices`.

    `positionAt` reports a vertex position; the returned lists stay within the
    authored vertex buffers, so a level only swaps the index list. A level that
    does not shrink the mesh is dropped.
*/
GeneratedLevel[] generateLevels(
    scope Vector3f delegate(size_t) positionAt,
    uint vertexCount,
    scope const(uint)[] indices,
    in Boxf bounds,
    uint levelCount = 3,
)
in(indices.length % 3 == 0)
{
    GeneratedLevel[] result;

    if(levelCount == 0 || vertexCount == 0 || indices.length < minTriangles * 3)
        return result;

    Boxf meshBounds = bounds;

    if(!hasBounds(meshBounds))
    {
        bool started;

        foreach(i; 0 .. vertexCount)
        {
            const p = positionAt(i);

            if(started)
                expandAABB(meshBounds, p);
            else
            {
                meshBounds = Boxf(p, p);
                started = true;
            }
        }
    }

    if(!hasBounds(meshBounds))
        return result;

    const diagonal = (meshBounds.max - meshBounds.min).length;

    if(!(diagonal > 0) || isNaN(diagonal))
        return result;

    size_t previous = indices.length;

    foreach(level; 1 .. levelCount + 1)
    {
        // Each level doubles the cell, so it roughly halves the triangles
        const cellSize = diagonal / (64u >> (level - 1));

        auto simpler = clusterLevel(positionAt, vertexCount, indices, cellSize, meshBounds.min);

        // A level has to earn its draw call, and one that vanishes is no level
        if(simpler.length == 0 || simpler.length + simpler.length / 4 >= previous)
            break;

        result ~= GeneratedLevel(simpler, cellSize);
        previous = simpler.length;
    }

    return result;
}

/// Minimum triangle count a mesh needs before levels are generated
private enum minTriangles = 256;

/// Vertices of one grid cell, so they collapse into one representative
private struct Cell
{
    int x;
    int y;
    int z;

    size_t toHash() const nothrow @safe
    {
        return (cast(size_t)(cast(uint) x) * 73856093u)
            ^ (cast(size_t)(cast(uint) y) * 19349663u)
            ^ (cast(size_t)(cast(uint) z) * 83492791u);
    }

    bool opEquals(const Cell other) const nothrow @safe
    {
        return x == other.x && y == other.y && z == other.z;
    }
}

/// Replaces every vertex by the first vertex of its cell and drops the triangles that collapse
private uint[] clusterLevel(
    scope Vector3f delegate(size_t) positionAt,
    uint vertexCount,
    scope const(uint)[] indices,
    float cellSize,
    in Vector3f origin,
)
{
    uint[] representativeOf;
    representativeOf.length = vertexCount;

    uint[Cell] representatives;

    foreach(i; 0 .. vertexCount)
    {
        const p = positionAt(i);

        const cell = Cell(
            cast(int) floor((p.x - origin.x) / cellSize),
            cast(int) floor((p.y - origin.y) / cellSize),
            cast(int) floor((p.z - origin.z) / cellSize),
        );

        if(auto found = cell in representatives)
            representativeOf[i] = *found;
        else
        {
            representatives[cell] = cast(uint) i;
            representativeOf[i] = cast(uint) i;
        }
    }

    auto result = appender!(uint[]);
    result.reserve(indices.length);

    for(size_t i = 0; i + 2 < indices.length; i += 3)
    {
        const a = representativeOf[indices[i]];
        const b = representativeOf[indices[i + 1]];
        const c = representativeOf[indices[i + 2]];

        if(a == b || b == c || a == c)
            continue;

        result ~= a;
        result ~= b;
        result ~= c;
    }

    return result.data;
}

/// Clip depth from which `error` stays under `lodTargetPixels` on screen
float lodDepth(float error, in Matrix4x4f mvp)
{
    // Row 1 of the clip transform scales the vertical axis
    const yScale = sqrt(
        mvp.arrayof[1] * mvp.arrayof[1]
        + mvp.arrayof[5] * mvp.arrayof[5]
        + mvp.arrayof[9] * mvp.arrayof[9]
    );

    return error * yScale * currentViewportHeight / (2 * lodTargetPixels);
}

/// Clip depth from which each level is coarse enough, finest first
float[] lodThresholds(scope const(float)[] errors, in Matrix4x4f mvp)
{
    float[] result;
    result.reserve(errors.length);

    foreach(error; errors)
        result ~= lodDepth(error, mvp);

    return result;
}

/// Coarsest level whose threshold the depth reaches
size_t pickLevel(scope const(float)[] thresholds, float depth)
{
    foreach_reverse(i; 0 .. thresholds.length)
        if(depth >= thresholds[i])
            return i;

    return 0;
}

/// Clip depth of the origin of `mvp`
float clipDepth(in Matrix4x4f mvp) => mvp.arrayof[15];

unittest
{
    // A dense grid loses triangles to every coarser level
    enum side = 100;

    Vector3f[] positions;
    uint[] indices;

    foreach(y; 0 .. side)
        foreach(x; 0 .. side)
            positions ~= Vector3f(cast(float) x, cast(float) y, 0);

    foreach(y; 0 .. side - 1)
        foreach(x; 0 .. side - 1)
        {
            const a = cast(uint)(y * side + x);
            const b = a + 1;
            const c = a + cast(uint) side;
            const d = c + 1;

            indices ~= [a, b, d, a, d, c];
        }

    auto levels = generateLevels(
        (size_t i) => positions[i],
        cast(uint) positions.length,
        indices,
        Boxf.init,
    );

    assert(levels.length > 0 && levels.length <= 3);
    assert(levels[0].indices.length < indices.length);

    foreach(i, level; levels)
    {
        assert(level.indices.length % 3 == 0);
        assert(level.error > 0);

        foreach(index; level.indices)
            assert(index < positions.length);

        if(i > 0)
            assert(level.error > levels[i - 1].error);
    }

    // A mesh too small for a level keeps its authored list only
    assert(generateLevels((size_t i) => positions[i], 3, [0, 1, 2], Boxf.init).length == 0);

    // The level follows the clip depth
    const thresholds = [0.0f, 10.0f, 20.0f];
    assert(pickLevel(thresholds, 5) == 0);
    assert(pickLevel(thresholds, 15) == 1);
    assert(pickLevel(thresholds, 25) == 2);
}
