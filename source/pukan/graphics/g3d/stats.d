module pukan.graphics.g3d.stats;

/**
    What the draws of one pass cost, counted where the commands are recorded.

    The numbers say what a frame submits to the GPU. What the cull kernel keeps
    stays on the GPU, so an indirect draw enters with the instances its batch
    was submitted with.
*/
struct DrawStats
{
    size_t draws;
    size_t instances;
    size_t triangles;

    void add(size_t submitDraws, size_t submitInstances, size_t submitTriangles)
    {
        draws += submitDraws;
        instances += submitInstances;
        triangles += submitTriangles;
    }

    DrawStats opBinary(string op)(in DrawStats other) const if(op == "+" || op == "-")
    {
        static if(op == "+")
            return DrawStats(draws + other.draws, instances + other.instances, triangles + other.triangles);
        else
            return DrawStats(draws - other.draws, instances - other.instances, triangles - other.triangles);
    }

    ref DrawStats opOpAssign(string op)(in DrawStats other) if(op == "+")
    {
        add(other.draws, other.instances, other.triangles);
        return this;
    }
}

/// Recording happens on the thread that builds the frame
private DrawStats submitted;

/// Clears the counters, so a pass measures on its own
void resetDrawStats()
{
    submitted = DrawStats.init;
}

/// Counters gathered since the last reset
DrawStats drawStats()
{
    return submitted;
}

/// Adds one recorded draw to the counters
package(pukan) void countDraw(size_t instances, size_t triangles)
{
    submitted.add(1, instances, triangles);
}

/// Triangles `count` elements of indices or vertices cover
package(pukan) size_t triangleCount(size_t count)
{
    return count / 3;
}

unittest
{
    resetDrawStats();
    countDraw(4, 12);
    countDraw(1, 2);

    const total = drawStats();

    assert(total == DrawStats(2, 5, 14));
    assert(total - DrawStats(1, 4, 12) == DrawStats(1, 1, 2));
    assert(DrawStats(1, 2, 3) + DrawStats(2, 3, 4) == DrawStats(3, 5, 7));
}
