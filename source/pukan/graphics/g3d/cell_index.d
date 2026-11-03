module pukan.graphics.g3d.cell_index;

import dlib.math: Matrix4x4f, Vector3f;
import pukan.graphics.common.misc: Boxf, hasBounds, partAabb, transformAabb;
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

/**
    One part of a drawable, in the drawable's own space.

    A part is the smallest piece a cell may hold and the smallest piece the
    drawable can record on its own: one mesh of a scene, or a child drawable
    whose interior is not reachable. `bounds` and `local` place it for cells,
    `key` brings it back to `PartDrawable.drawParts`.
*/
struct Part
{
    /// Bounds in the part's own space
    Boxf bounds;
    /// Transform in the drawable's space
    Matrix4x4f local;
    /// Handle that `drawParts` takes for this part
    size_t key;
}

/**
    A drawable that splits itself into parts, so a cell can hold each one.

    The index asks `eachPart` once and stores a key per part of every cell its
    bounds reach. A view then hands the keys of its resident cells back to
    `drawParts`, so a frame records only what those cells hold and never walks
    the node tree.

    A drawable that cannot record a part on its own stays whole: the index gives
    it one item and `drawCells` records it through `drawingBufferFilling`.
*/
interface PartDrawable
{
    /// Reports every part once; the keys stay valid for the drawable's life
    void eachPart(scope void delegate(in Part part) dg);

    /// Uploads the parts; the caller holds them until `releaseParts`
    void loadParts(VkCommandBuffer buf, scope const(size_t)[] keys);

    /// Drops the caller's hold; resources go when nothing else holds them
    void releaseParts(scope const(size_t)[] keys);

    /**
        Records the given parts in one batch.

        `trans` maps the drawable's space into clip space, so the caller passes
        its view-projection times the transform that places the drawable. Keys
        come from `eachPart`; an empty list records nothing.
    */
    void drawParts(
        VkCommandBuffer buf,
        in Matrix4x4f trans,
        scope const(size_t)[] keys,
        VkDescriptorSet frameSet,
        DrawPhase phase,
    );
}

/// `DrawItem.part` of a drawable that records as a whole
enum wholePart = size_t.max;

/**
    One part in the world, as a cell holds it.

    `world` places the drawable, not the part: parts keep their transforms inside
    the drawable, so the same base serves every key of it. `part` is `wholePart`
    for a drawable that records as a whole.
*/
struct DrawItem
{
    DrawableByVulkan drawable;
    Matrix4x4f world;
    size_t part = wholePart;
}

/// Places a drawable into the index at `world`, one item per part or one whole
void placeDrawable(CellIndex!DrawItem index, DrawableByVulkan drawable, in Matrix4x4f world)
{
    if(auto partDrawable = cast(PartDrawable) drawable)
        partDrawable.eachPart((in Part part) {
            const placed = world * part.local;
            index.insert(DrawItem(drawable, world, part.key), partAabb(part.bounds, placed));
        });
    else
    {
        auto bounded = cast(Bounded) drawable;
        const local = bounded is null ? Boxf.init : bounded.cellBounds;

        index.insert(
            DrawItem(drawable, world, wholePart),
            hasBounds(local) ? transformAabb(local, world) : Boxf.init,
        );
    }
}

/**
    Records the parts of the given cells, as a view sees them.

    Parts of one drawable are handed to `drawParts` together, so the drawable
    still batches them; a drawable that records as a whole is recorded once,
    even when the cells hold several of its items.
*/
void drawCells(
    CellIndex!DrawItem index,
    VkCommandBuffer buf,
    in Matrix4x4f viewProj,
    scope const(CellCoord)[] cells,
    VkDescriptorSet frameSet,
    DrawPhase phase = DrawPhase.surface,
)
{
    auto items = index.collect(cells);

    static struct Group
    {
        DrawableByVulkan drawable;
        Matrix4x4f world;
        size_t[] keys;
    }

    Group[] groups;

    foreach(i, item; items)
    {
        if(item.part != wholePart)
        {
            size_t found = groups.length;

            foreach(g, group; groups)
                if(group.drawable is item.drawable)
                {
                    found = g;
                    break;
                }

            if(found == groups.length)
                groups ~= Group(item.drawable, item.world);

            groups[found].keys ~= item.part;

            continue;
        }

        bool seen;

        foreach(j; 0 .. i)
            if(items[j].drawable is item.drawable)
            {
                seen = true;
                break;
            }

        if(!seen)
            item.drawable.drawingBufferFilling(buf, viewProj * item.world, frameSet, phase);
    }

    foreach(group; groups)
        (cast(PartDrawable) group.drawable).drawParts(
            buf, viewProj * group.world, group.keys, frameSet, phase);
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

    /// Every cell that holds an item
    CellCoord[] cells() const
    {
        CellCoord[] result;
        result.reserve(byCell.length);

        foreach(cell; byCell.byKey)
            result ~= cell;

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
