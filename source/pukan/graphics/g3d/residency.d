module pukan.graphics.g3d.residency;

import dlib.math: dot, Vector3f;
import pukan.graphics.common.misc: Boxf;
import pukan.graphics.g3d.cells: CellCoord, CellGrid;
import std.algorithm: canFind, max, min, sort;
import std.math: sqrt;

/// What a streaming source asks of the cells it reaches
enum CellState
{
    /// No source reaches the cell
    empty,
    /// The cell exists but is not drawn
    loaded,
    /// The cell is drawn
    active,
}

/// One point that keeps cells alive around itself
struct StreamingSource
{
    Vector3f position;
    /// Heading that makes cells ahead load first; zero ignores the angle
    Vector3f forward = Vector3f(0, 0, 0);
    /// Cells whose bounds lie within this distance of the point are wanted
    float range = 384.0f;
    /// The highest priority wins when sources disagree about a cell
    uint priority;
    /// What the source asks of the cells it reaches
    CellState state = CellState.active;
}

/// Cells kept around the streaming sources, nearest first, with one budget per update
final class Residency
{
    /// Cell size and level origin; set before the first update
    CellGrid grid;
    /// How much the angle to a cell stretches its distance, like Unreal's angle contribution
    float angleWeight = 0.25f;
    /// A retired cell waits this many frames, so the frames in flight can still draw it
    uint framesInFlight = 2;

    private CellCoord[] loadedCells;
    private CellCoord[] pendingCells;
    private CellCoord[] activeCells;
    /// Frame a retired cell may leave after
    private size_t[CellCoord] retiredAt;

    this(CellGrid grid)
    {
        this.grid = grid;
    }

    /// The cells the camera draws
    const(CellCoord)[] active() const => activeCells;

    /// The cells the sources want and that are not loaded yet, most important first
    const(CellCoord)[] pending() const => pendingCells;

    /// The cells the caller has loaded and not released
    const(CellCoord)[] loaded() const => loadedCells;

    /// Recomputes the wanted cells and their order for the sources
    void update(scope const(StreamingSource)[] sources, size_t frame)
    {
        struct Wanted
        {
            CellCoord cell;
            CellState state;
            uint priority;
            float importance;
        }

        Wanted[CellCoord] wanted;

        foreach(source; sources)
        {
            const margin = Vector3f(source.range, source.range, source.range);

            foreach(cell; grid.cellsIn(Boxf(source.position - margin, source.position + margin)))
            {
                const distance = distanceTo(cell, source.position);

                if(distance > source.range)
                    continue;

                const importance = importanceOf(source, cell, distance);

                if(auto existing = cell in wanted)
                {
                    existing.state = max(existing.state, source.state);
                    existing.priority = max(existing.priority, source.priority);
                    existing.importance = min(existing.importance, importance);
                }
                else
                    wanted[cell] = Wanted(cell, source.state, source.priority, importance);
            }
        }

        Wanted[] ordered;

        foreach(value; wanted.byValue)
            ordered ~= value;

        // A cell of higher priority goes first; then what the sources reach soonest
        ordered.sort!((a, b) => a.priority != b.priority
            ? a.priority > b.priority
            : a.importance < b.importance);

        bool[CellCoord] wantedCells;
        CellCoord[] active;

        foreach(w; ordered)
        {
            wantedCells[w.cell] = true;

            if(w.state == CellState.active)
                active ~= w.cell;
        }

        // A retired cell the sources need again never left, so it keeps its resources
        foreach(w; ordered)
            retiredAt.remove(w.cell);

        foreach(cell; loadedCells)
            if(cell !in wantedCells && cell !in retiredAt)
                retiredAt[cell] = frame;

        bool[CellCoord] known;

        foreach(cell; loadedCells)
            known[cell] = true;

        activeCells = active;
        pendingCells = null;

        foreach(w; ordered)
        {
            if(w.cell in known)
                continue;

            pendingCells ~= w.cell;
            known[w.cell] = true;
        }
    }

    /// Cells to load now, at most `budget` of them, most important first
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

    /// Distance from the point to the nearest point of the cell
    private float distanceTo(CellCoord cell, Vector3f position) const
    {
        const box = grid.bounds(cell);
        float squared = 0;

        foreach(axis; 0 .. 3)
        {
            const v = position[axis];

            if(v < box.min[axis])
                squared += (box.min[axis] - v) * (box.min[axis] - v);
            else
            if(v > box.max[axis])
                squared += (v - box.max[axis]) * (v - box.max[axis]);
        }

        return sqrt(squared);
    }

    /// Distance stretched by the angle to the cell, so what lies ahead comes first
    private float importanceOf(in StreamingSource source, CellCoord cell, float distance) const
    {
        const forward = source.forward.length;

        if(forward < 1e-6f || distance < 1e-3f)
            return distance;

        const box = grid.bounds(cell);
        const toCell = (box.min + box.max) * 0.5f - source.position;

        if(toCell.length < 1e-6f)
            return distance;

        const cos = dot(toCell, source.forward) / (toCell.length * forward);

        return distance * (1 + angleWeight * (1 - cos));
    }
}

unittest
{
    const grid = CellGrid(10);

    auto residency = new Residency(grid);
    residency.framesInFlight = 2;

    // The active source draws its own range, a wider loaded source only keeps cells
    StreamingSource activeSource(Vector3f position, float range, uint priority = 0)
    {
        return StreamingSource(position, Vector3f(0, 0, 0), range, priority, CellState.active);
    }

    StreamingSource loadedSource(Vector3f position, float range, uint priority = 0)
    {
        return StreamingSource(position, Vector3f(0, 0, 0), range, priority, CellState.loaded);
    }

    const eye = Vector3f(5, 5, 5);

    residency.update([activeSource(eye, 4), loadedSource(eye, 6)], 0);

    // The cell around the eye is active, the six neighbours are only loaded
    assert(residency.active == [CellCoord(0, 0, 0)]);
    assert(residency.pending.length == 7);
    assert(residency.pending.canFind(CellCoord(1, 0, 0)));
    assert(!residency.pending.canFind(CellCoord(1, 1, 0)), "a diagonal cell is out of reach");

    // The budget splits the prefetch over frames
    assert(residency.take(4).length == 4);
    assert(residency.loaded.length == 4);

    residency.update([activeSource(eye, 4), loadedSource(eye, 6)], 1);
    assert(residency.pending.length == 3);
    assert(residency.take(4).length == 3);
    assert(residency.loaded.length == 7);

    // Leaving retires the cells, but their frames in flight keep them
    const away = Vector3f(505, 5, 5);
    residency.update([activeSource(away, 4), loadedSource(away, 6)], 2);
    assert(residency.release(3).length == 0);

    // Coming back before the delay keeps them loaded
    residency.update([activeSource(eye, 4), loadedSource(eye, 6)], 3);
    assert(residency.release(5).length == 0);
    assert(residency.loaded.length == 7);

    // Leaving for good releases them after the delay
    residency.update([activeSource(away, 4), loadedSource(away, 6)], 6);
    assert(residency.release(8).length == 7);
    assert(residency.loaded.length == 0);

    // A cell ahead of the source comes before one behind it
    auto ahead = new Residency(grid);
    ahead.update([StreamingSource(Vector3f(5, 5, 5), Vector3f(1, 0, 0), 40)], 0);
    assert(ahead.pending.canFind(CellCoord(3, 0, 0)));
    assert(ahead.pending.canFind(CellCoord(-3, 0, 0)));
    assert(ahead.pending[0] != CellCoord(-3, 0, 0), "the cell behind loads last");

    bool aheadBeforeBehind;
    foreach(cell; ahead.pending)
    {
        if(cell == CellCoord(3, 0, 0))
            aheadBeforeBehind = true;
        else if(cell == CellCoord(-3, 0, 0))
            break;
    }
    assert(aheadBeforeBehind, "the cell ahead loads first");

    // A higher priority wins over a closer, lower priority source
    auto priorities = new Residency(grid);
    priorities.update([
        StreamingSource(Vector3f(5, 5, 5), Vector3f(0, 0, 0), 4, 0, CellState.loaded),
        StreamingSource(Vector3f(45, 5, 5), Vector3f(0, 0, 0), 6, 5, CellState.loaded),
    ], 0);

    assert(priorities.pending.length > 0);
    assert(priorities.pending[0] == CellCoord(4, 0, 0), "the priority source goes first");
}
