module pukan.graphics.g3d.cell_index;

import dlib.math: Matrix4x4f, Vector3f;
import pukan.graphics.common.misc: Boxf, hasBounds;
import pukan.graphics.g3d.cells: CellCoord, CellGrid;
import pukan.vulkan.bindings: VkCommandBuffer, VkDescriptorSet;
import pukan.vulkan.renderpass: DrawableByVulkan, DrawPhase;

/// A drawable that can report its bounds in its own space, so cells can place it
interface Bounded
{
    /// Space the drawable occupies; NaN when no part reports extents
    Boxf localBounds();

    /// Bounds for cell placement; a part without extents may contribute its origin
    Boxf cellBounds();
}

/// One part of a drawable, as a cell holds it
struct Part
{
    /// Bounds in the part's own space
    Boxf bounds;
    /// Transform in the drawable's space
    Matrix4x4f local;
    /// Handle that `drawPart` takes for this part
    size_t key;
}

/// A drawable that places and records its own parts, so a cell can hold each one
interface PartDrawable
{
    /// Reports every part with bounds and transform, both in the drawable's space
    void eachPart(scope void delegate(in Part part) dg);

    /// Records the part with `trans`, the view-projection times its world transform
    void drawPart(
        VkCommandBuffer buf,
        in Matrix4x4f trans,
        size_t key,
        VkDescriptorSet frameSet,
        DrawPhase phase,
    );
}

/// `DrawItem.part` of a drawable that records as a whole
enum wholePart = size_t.max;

/// One part in the world; `part` is `wholePart` when the drawable records as a whole
struct DrawItem
{
    DrawableByVulkan drawable;
    Matrix4x4f world;
    size_t part = wholePart;
}

/// Cells of a grid mapped to the items whose bounds touch them
final class CellIndex(T)
{
    private CellGrid cellGrid;
    private T[] items;
    /// Cell to indices in `items`; one item may sit in several cells
    private size_t[][CellCoord] byCell;
    /// Items without bounds are visible from every cell
    private size_t[] always;
    private size_t placements;

    this(CellGrid grid)
    {
        cellGrid = grid;
    }

    CellGrid grid() const => cellGrid;

    /// Places the item into every cell its bounds touch
    void insert(T item, in Boxf bounds)
    {
        const index = items.length;
        items ~= item;

        if(!hasBounds(bounds))
        {
            always ~= index;
            return;
        }

        foreach(cell; cellGrid.cellsIn(bounds))
        {
            byCell[cell] ~= index;
            ++placements;
        }
    }

    /// Items touching any of the cells, each once
    T[] collect(scope const(CellCoord)[] cells) const
    {
        bool[] seen;
        seen.length = items.length;

        T[] result;

        foreach(index; always)
        {
            seen[index] = true;
            result ~= cast(T) items[index];
        }

        foreach(cell; cells)
            if(auto found = cell in byCell)
                foreach(index; *found)
                    if(!seen[index])
                    {
                        seen[index] = true;
                        result ~= cast(T) items[index];
                    }

        return result;
    }

    /// Items no cell can hold, so every query returns them
    T[] alwaysVisible() const
    {
        T[] result;
        result.reserve(always.length);

        foreach(index; always)
            result ~= cast(T) items[index];

        return result;
    }

    size_t itemCount() const => items.length;

    size_t cellCount() const => byCell.length;

    /// Cell placements over all items; above `itemCount` when items cross borders
    size_t placementCount() const => placements;
}

unittest
{
    const grid = CellGrid(10);
    auto index = new CellIndex!int(grid);

    Boxf box(float x, float y, float z) => Boxf(Vector3f(x, y, z), Vector3f(x + 1, y + 1, z + 1));

    // A box inside one cell is placed once
    index.insert(1, box(1, 1, 1));
    assert(index.itemCount == 1);
    assert(index.cellCount == 1);
    assert(index.placementCount == 1);
    assert(index.collect([grid.of(Vector3f(1.5f, 1.5f, 1.5f))]) == [1]);

    // A box across a border sits in both cells and is still collected once
    index.insert(2, Boxf(Vector3f(9, 1, 1), Vector3f(11, 2, 2)));
    assert(index.placementCount == 3);
    assert(index.cellCount == 2);

    const both = [grid.of(Vector3f(1.5f, 1.5f, 1.5f)), grid.of(Vector3f(10.5f, 1.5f, 1.5f))];
    assert(index.collect(both) == [1, 2]);

    // An item without bounds is visible from a cell it was never placed in
    index.insert(3, Boxf.init);
    assert(index.alwaysVisible == [3]);
    assert(index.collect([grid.of(Vector3f(-100, -100, -100))]) == [3]);

    // Negative cells come from floor division, not truncation
    index.insert(4, box(-5, -5, -5));
    assert(index.collect([grid.of(Vector3f(-5, -5, -5))]) == [3, 4]);
}
