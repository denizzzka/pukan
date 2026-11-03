module pukan.graphics.g3d.residency;

import dlib.math: Vector3f;
import pukan.graphics.common.misc: Boxf;
import pukan.graphics.g3d.cells: CellCoord, CellGrid;
import std.algorithm: canFind, max, sort;
import std.math: sqrt;

/// Cells kept around the camera, nearest first, with one budget per update
final class Residency
{
    /// Cell size and level origin; set before the first update
    CellGrid grid;
    /// Cells within this distance of the eye are the ones the camera draws
    float residentRadius = 256.0f;
    /// Cells within this distance are prefetched, nearest first
    float prefetchRadius = 384.0f;
    /// A retired cell waits this many frames, so the frames in flight can still draw it
    uint framesInFlight = 2;

    private CellCoord[] loadedCells;
    private CellCoord[] pendingCells;
    private CellCoord[] residentCells;
    /// Frame a retired cell may leave after
    private size_t[CellCoord] retiredAt;

    this(CellGrid grid)
    {
        this.grid = grid;
    }

    /// The cells the camera draws from
    const(CellCoord)[] resident() const => residentCells;

    /// The cells the eye wants and that are not loaded yet, nearest first
    const(CellCoord)[] pending() const => pendingCells;

    /// The cells the caller has loaded and not released
    const(CellCoord)[] loaded() const => loadedCells;

    /// Recomputes the wanted set and its order for the eye
    void update(Vector3f eye, size_t frame)
    {
        const float reach = max(residentRadius, prefetchRadius);
        const margin = Vector3f(reach, reach, reach);

        struct Wanted
        {
            CellCoord cell;
            float distance;
        }

        Wanted[] wanted;

        foreach(cell; grid.cellsIn(Boxf(eye - margin, eye + margin)))
        {
            const distance = distanceTo(cell, eye);

            if(distance <= reach)
                wanted ~= Wanted(cell, distance);
        }

        // Nearest first, so the budget spends on what the camera reaches next
        wanted.sort!((a, b) => a.distance < b.distance);

        bool[CellCoord] wantedCells;

        foreach(w; wanted)
            wantedCells[w.cell] = true;

        // A retired cell the eye needs again never left, so it keeps its resources
        foreach(w; wanted)
            retiredAt.remove(w.cell);

        foreach(cell; loadedCells)
            if(cell !in wantedCells && cell !in retiredAt)
                retiredAt[cell] = frame;

        bool[CellCoord] known;

        foreach(cell; loadedCells)
            known[cell] = true;

        residentCells = null;
        pendingCells = null;

        foreach(w; wanted)
        {
            if(w.distance <= residentRadius)
                residentCells ~= w.cell;

            if(w.cell in known)
                continue;

            pendingCells ~= w.cell;
            known[w.cell] = true;
        }
    }

    /// Cells to load now, at most `budget` of them, nearest first
    CellCoord[] take(size_t budget)
    {
        if(budget > pendingCells.length)
            budget = pendingCells.length;

        auto taken = pendingCells[0 .. budget];

        pendingCells = pendingCells[budget .. $];
        loadedCells ~= taken;

        return taken;
    }

    /// Cells whose retire delay has passed and whose resources may go
    CellCoord[] release(size_t frame)
    {
        CellCoord[] gone;

        foreach(cell, retired; retiredAt)
            if(retired + framesInFlight <= frame)
                gone ~= cell;

        if(gone.length == 0)
            return null;

        CellCoord[] kept;
        kept.reserve(loadedCells.length - gone.length);

        foreach(cell; loadedCells)
            if(!gone.canFind(cell))
                kept ~= cell;

        loadedCells = kept;

        foreach(cell; gone)
            retiredAt.remove(cell);

        return gone;
    }

    /// Distance from the eye to the nearest point of the cell
    private float distanceTo(CellCoord cell, Vector3f eye) const
    {
        const box = grid.bounds(cell);
        float squared = 0;

        foreach(axis; 0 .. 3)
        {
            const v = eye[axis];

            if(v < box.min[axis])
                squared += (box.min[axis] - v) * (box.min[axis] - v);
            else
            if(v > box.max[axis])
                squared += (v - box.max[axis]) * (v - box.max[axis]);
        }

        return sqrt(squared);
    }
}

unittest
{
    import pukan.graphics.g3d.cells: CellCoord;

    auto residency = new Residency(CellGrid(10));
    residency.residentRadius = 4;
    residency.prefetchRadius = 6;
    residency.framesInFlight = 2;

    const eye = Vector3f(5, 5, 5);

    // The cell around the eye is resident, the six neighbours are prefetched
    residency.update(eye, 0);
    assert(residency.resident == [CellCoord(0, 0, 0)]);
    assert(residency.pending.length == 7);
    assert(residency.pending.canFind(CellCoord(1, 0, 0)));
    assert(!residency.pending.canFind(CellCoord(1, 1, 0)), "a diagonal cell is out of reach");

    // The budget splits the prefetch over frames
    assert(residency.take(4).length == 4);
    assert(residency.loaded.length == 4);

    residency.update(eye, 1);
    assert(residency.pending.length == 3);

    assert(residency.take(4).length == 3);
    assert(residency.pending.length == 0);
    assert(residency.loaded.length == 7);

    // Leaving retires the cells, but their frames in flight keep them
    residency.update(Vector3f(505, 5, 5), 2);
    assert(residency.release(3).length == 0);

    // Coming back before the delay keeps them loaded
    residency.update(eye, 3);
    assert(residency.release(5).length == 0);
    assert(residency.loaded.length == 7);

    // Leaving for good releases them after the delay
    residency.update(Vector3f(505, 5, 5), 6);
    assert(residency.release(8).length == 7);
    assert(residency.loaded.length == 0);
}
