module pukan.graphics.g3d.cells;

import dlib.math: Vector3f;
import pukan.graphics.common.misc: Boxf, hasBounds;
import std.math: floor;

/// Integer cell of a `CellGrid`; exact far from the level origin
struct CellCoord
{
    int x;
    int y;
    int z;
}

/// Fixed-size partition of the world, the unit of residency and culling
struct CellGrid
{
    /// Edge length of a cell in world units
    float cellSize = 64.0f;
    /// Minimum corner of cell (0, 0, 0)
    Vector3f origin = Vector3f(0, 0, 0);

    /// Cell that holds the point
    CellCoord of(Vector3f p) const
    {
        return CellCoord(
            index(p.x, origin.x),
            index(p.y, origin.y),
            index(p.z, origin.z),
        );
    }

    /// World bounds of the cell
    Boxf bounds(CellCoord c) const
    {
        const start = origin + Vector3f(cast(float) c.x, cast(float) c.y, cast(float) c.z) * cellSize;

        return Boxf(start, start + Vector3f(cellSize, cellSize, cellSize));
    }

    /// Cells the box touches; empty when the box has no bounds
    CellRange cellsIn(in Boxf box) const
    {
        if(!hasBounds(box))
            return CellRange.init;

        return CellRange(of(box.min), of(box.max));
    }

    private int index(float value, float start) const
    {
        assert(cellSize > 0, "cell size must be positive");

        // floor, not truncation: the point just below the origin is one cell back
        return cast(int) floor((value - start) / cellSize);
    }
}

/// Cells of a rectangular region, x fastest
struct CellRange
{
    private CellCoord first;
    private CellCoord last;
    private CellCoord current;
    private bool spent = true;

    this(CellCoord first, CellCoord last)
    {
        this.first = first;
        this.last = last;
        this.current = first;
        this.spent = first.x > last.x || first.y > last.y || first.z > last.z;
    }

    bool empty() const => spent;

    CellCoord front() const => current;

    void popFront()
    {
        if(++current.x <= last.x)
            return;

        current.x = first.x;

        if(++current.y <= last.y)
            return;

        current.y = first.y;

        if(++current.z <= last.z)
            return;

        spent = true;
    }
}

unittest
{
    const grid = CellGrid(10);

    // Floor division keeps the cell just below the origin on the left side
    assert(grid.of(Vector3f(0, 0, 0)) == CellCoord(0, 0, 0));
    assert(grid.of(Vector3f(9.999f, 0, 0)) == CellCoord(0, 0, 0));
    assert(grid.of(Vector3f(10, 0, 0)) == CellCoord(1, 0, 0));
    assert(grid.of(Vector3f(-0.001f, 0, 0)) == CellCoord(-1, 0, 0));
    assert(grid.of(Vector3f(-10, 0, 0)) == CellCoord(-1, 0, 0));
    assert(grid.of(Vector3f(-10.001f, -20, 0)) == CellCoord(-2, -2, 0));

    // The origin shifts the whole partition, not only the corner cell
    auto shifted = CellGrid(10);
    shifted.origin = Vector3f(5, 0, 0);
    assert(shifted.of(Vector3f(5, 0, 0)) == CellCoord(0, 0, 0));
    assert(shifted.of(Vector3f(4.9f, 0, 0)) == CellCoord(-1, 0, 0));
    assert(shifted.bounds(CellCoord(1, 0, 0)) == Boxf(Vector3f(15, 0, 0), Vector3f(25, 10, 10)));

    // A box inside one cell touches one cell
    import std.range: walkLength;

    assert(grid.cellsIn(Boxf(Vector3f(1, 1, 1), Vector3f(2, 2, 2))).walkLength == 1);

    // A box across a border touches both cells, and a corner gives four
    assert(grid.cellsIn(Boxf(Vector3f(9, 1, 1), Vector3f(11, 2, 2))).walkLength == 2);
    assert(grid.cellsIn(Boxf(Vector3f(9, 9, 1), Vector3f(11, 11, 2))).walkLength == 4);
    assert(grid.cellsIn(Boxf(Vector3f(9, 9, 9), Vector3f(11, 11, 11))).walkLength == 8);

    // A max corner just below the border stays in one cell, on the border it touches the next
    assert(grid.cellsIn(Boxf(Vector3f(0, 0, 0), Vector3f(9.999f, 9.999f, 9.999f))).walkLength == 1);
    assert(grid.cellsIn(Boxf(Vector3f(0, 0, 0), Vector3f(10, 10, 10))).walkLength == 8);

    // A box without bounds has no cells, so it never disappears by accident
    assert(grid.cellsIn(Boxf.init).walkLength == 0);

    // The range walks x first, then y, then z
    auto cells = grid.cellsIn(Boxf(Vector3f(0, 0, 0), Vector3f(20, 20, 20)));
    assert(cells.front == CellCoord(0, 0, 0));
    cells.popFront();
    assert(cells.front == CellCoord(1, 0, 0));
    cells.popFront();
    assert(cells.front == CellCoord(2, 0, 0));
    cells.popFront();
    assert(cells.front == CellCoord(0, 1, 0));
}
