module pukan.graphics.g3d.cell_index;

import dlib.math: Matrix4x4f, Vector3f;
import pukan.graphics.common.bvh: BoxBvh;
import pukan.graphics.common.misc: Boxf, hasBounds, isVisible, partAabb, transformAabb;
import pukan.graphics.g3d.cells: CellCoord, CellGrid;
import pukan.graphics.g3d.pbr.mesh: PbrMesh;
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

    /// Keeps the parts loaded; `releaseParts` drops the hold
    void holdParts(scope const(size_t)[] keys);

    /// Drops the caller's hold; resources go when nothing else holds them
    void releaseParts(scope const(size_t)[] keys);

    /// Uploads what the held parts miss, at most `budget` bytes; returns bytes used
    size_t uploadParts(VkCommandBuffer buf, size_t budget);

    /// Name of the part, for a pick report or a debug label
    string partName(size_t key);

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

/// Who decides which parts of the cells a view records
enum CellCulling
{
    /// The cell trees and the part bounds decide on the CPU
    cpu,
    /// The cull kernel decides on the GPU, from what `gatherCells` collected
    gpu,
}

/**
    A drawable that culls its parts on the GPU.

    `gatherCells` calls `beginGather` once per view, hands every placement to
    `gatherParts` and then lets `endGather` upload the instances and dispatch
    the cull kernel. `drawCells` records what the kernel kept, so a phase is
    gathered and drawn once per frame.
*/
interface CulledParts
{
    /// Starts a new instance list for the phase
    void beginGather(DrawPhase phase);

    /// Adds the parts of one placement to the list; `trans` maps it into clip space
    void gatherParts(VkCommandBuffer buf, in Matrix4x4f trans, scope const(size_t)[] keys, DrawPhase phase);

    /// Uploads the gathered instances and dispatches the cull kernel
    void endGather(VkCommandBuffer buf, DrawPhase phase);

    /// Records the draws the kernel kept
    void drawGathered(VkCommandBuffer buf, VkDescriptorSet frameSet, DrawPhase phase);
}

/// A nested drawable that hands its static meshes to the parent's gather
interface MeshParts
{
    /**
        Visits every static mesh of the drawable with the transform that places
        it inside the drawable. Returns false, and visits nothing, when some
        mesh has to stay on the CPU path - a skinned one moves with its pose -
        so the caller can draw the drawable whole instead.
    */
    bool eachStaticMesh(scope void delegate(PbrMesh mesh, in Matrix4x4f world) sink);
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
    /// Bounds in world space; NaN when the part reports none
    Boxf bounds;
}

/// Places a drawable into the index at `world`, one item per part or one whole
void placeDrawable(CellIndex!DrawItem index, DrawableByVulkan drawable, in Matrix4x4f world)
{
    if(auto partDrawable = cast(PartDrawable) drawable)
        partDrawable.eachPart((in Part part) {
            const placed = world * part.local;
            const bounds = partAabb(part.bounds, placed);

            index.insert(DrawItem(drawable, world, part.key, bounds), bounds);
        });
    else
    {
        auto bounded = cast(Bounded) drawable;
        const local = bounded is null ? Boxf.init : bounded.cellBounds;
        const bounds = hasBounds(local) ? transformAabb(local, world) : Boxf.init;

        index.insert(DrawItem(drawable, world, wholePart, bounds), bounds);
    }
}

/// Groups the keyed parts of the cells by drawable and the transform that places it
private void groupItems(
    DrawItem[] items,
    scope void delegate(DrawableByVulkan drawable, in Matrix4x4f world, scope const(size_t)[] keys) dg,
    bool boundedOnly = false,
)
{
    static struct Group
    {
        DrawableByVulkan drawable;
        Matrix4x4f world;
        size_t[] keys;
    }

    Group[] groups;

    foreach(item; items)
    {
        if(item.part == wholePart)
            continue;

        // A part without bounds belongs to no cell, so no cell may hold or release it
        if(boundedOnly && !hasBounds(item.bounds))
            continue;

        size_t found = groups.length;

        foreach(g, group; groups)
            if(group.drawable is item.drawable && group.world == item.world)
            {
                found = g;
                break;
            }

        if(found == groups.length)
            groups ~= Group(item.drawable, item.world);

        groups[found].keys ~= item.part;
    }

    foreach(group; groups)
        dg(group.drawable, group.world, group.keys);
}

/// Groups every part of the cells, without a view
private void groupParts(
    CellIndex!DrawItem index,
    scope const(CellCoord)[] cells,
    scope void delegate(DrawableByVulkan drawable, in Matrix4x4f world, scope const(size_t)[] keys) dg,
    bool boundedOnly = false,
)
{
    groupItems(index.collect(cells), dg, boundedOnly);
}

/// Keeps the parts of the cells loaded; `releaseCells` drops the hold
void holdCells(CellIndex!DrawItem index, scope const(CellCoord)[] cells)
{
    groupParts(index, cells, (drawable, world, keys) {
        (cast(PartDrawable) drawable).holdParts(keys);
    }, true);
}

/// Drops the hold the cells had on their parts
void releaseCells(CellIndex!DrawItem index, scope const(CellCoord)[] cells)
{
    groupParts(index, cells, (drawable, world, keys) {
        (cast(PartDrawable) drawable).releaseParts(keys);
    }, true);
}

/// Uploads what the held parts of the cells miss, at most `budget` bytes
size_t uploadCells(
    CellIndex!DrawItem index,
    VkCommandBuffer buf,
    scope const(CellCoord)[] cells,
    size_t budget,
)
{
    size_t used;

    groupParts(index, cells, (drawable, world, keys) {
        if(used >= budget)
            return;

        used += (cast(PartDrawable) drawable).uploadParts(buf, budget - used);
    });

    return used;
}

/// Collects the parts of the cells for the cull kernel; `drawCells` draws what it kept
void gatherCells(
    CellIndex!DrawItem index,
    VkCommandBuffer buf,
    in Matrix4x4f viewProj,
    scope const(CellCoord)[] cells,
    DrawPhase phase,
)
{
    auto items = index.collect(cells);

    DrawableByVulkan[] cullable;

    foreach(item; items)
    {
        if(!(cast(CulledParts) item.drawable))
            continue;

        bool seen;

        foreach(drawable; cullable)
            if(drawable is item.drawable)
            {
                seen = true;
                break;
            }

        if(!seen)
            cullable ~= item.drawable;
    }

    foreach(drawable; cullable)
        (cast(CulledParts) drawable).beginGather(phase);

    groupItems(items, (drawable, world, keys) {
        if(auto parts = cast(CulledParts) drawable)
            parts.gatherParts(buf, viewProj * world, keys, phase);
    });

    foreach(drawable; cullable)
        (cast(CulledParts) drawable).endGather(buf, phase);
}

/// What one view took from the cells
struct DrawStats
{
    /// Cells the view asked for
    size_t cells;
    /// Item placements in those cells, one per cell an item touches
    size_t placements;
    /// Parts the drawables recorded
    size_t parts;
    /// Whole drawables recorded
    size_t drawables;
}

/**
    Records the parts of the given cells, as a view sees them.

    Parts of one drawable are handed to `drawParts` together, so the drawable
    still batches them; a drawable that records as a whole is recorded once,
    even when the cells hold several of its items.
*/
DrawStats drawCells(
    CellIndex!DrawItem index,
    VkCommandBuffer buf,
    in Matrix4x4f viewProj,
    scope const(CellCoord)[] cells,
    VkDescriptorSet frameSet,
    DrawPhase phase = DrawPhase.surface,
    CellCulling culling = CellCulling.cpu,
)
{
    DrawStats stats;
    stats.cells = cells.length;
    stats.placements = index.placementsIn(cells);

    auto items = culling == CellCulling.gpu
        ? index.collect(cells)
        : index.visible(cells, viewProj);

    foreach(i, item; items)
    {
        if(item.part != wholePart)
            continue;

        // The tree culls by node bounds, so the item box answers for itself
        if(!isVisible(item.bounds, viewProj))
            continue;

        bool seen;

        foreach(j; 0 .. i)
            if(items[j].drawable is item.drawable)
            {
                seen = true;
                break;
            }

        if(!seen)
        {
            item.drawable.drawingBufferFilling(buf, viewProj * item.world, frameSet, phase);
            ++stats.drawables;
        }
    }

    // Parts of one drawable go together, so it still batches them
    DrawableByVulkan[] drawn;

    groupItems(items, (drawable, world, keys) {
        if(culling == CellCulling.gpu)
            if(auto parts = cast(CulledParts) drawable)
            {
                foreach(d; drawn)
                    if(d is drawable)
                        return;

                drawn ~= drawable;
                parts.drawGathered(buf, frameSet, phase);
                return;
            }

        stats.parts += keys.length;

        (cast(PartDrawable) drawable).drawParts(buf, viewProj * world, keys, frameSet, phase);
    });

    return stats;
}

/// Cells of a grid mapped to the items whose bounds touch them
final class CellIndex(T)
{
    private CellGrid cellGrid;
    private T[] items;
    /// Bounds per item, in world space; NaN for an item no cell can hold
    private Boxf[] itemBounds;
    /// Cell to indices in `items`; one item may sit in several cells
    private size_t[][CellCoord] byCell;
    /// Items without bounds are visible from every cell
    private size_t[] always;
    private size_t placements;
    /// Culling and picking tree per cell, built on the first query
    private CellTree[CellCoord] cellTrees;

    private struct CellTree
    {
        size_t[] items;
        BoxBvh bvh;
    }

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
        itemBounds ~= bounds;

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

    /// Items of the cells that pass the frustum, each once, plus the unbounded ones
    T[] visible(scope const(CellCoord)[] cells, in Matrix4x4f viewProj)
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
        {
            auto tree = treeOf(cell);

            if(tree is null || tree.bvh is null)
                continue;

            tree.bvh.queryVisible(viewProj, (local) {
                const index = tree.items[local];

                if(seen[index])
                    return;

                seen[index] = true;
                result ~= cast(T) items[index];
            });
        }

        return result;
    }

    /// Nearest item of the cells the ray enters within `maxT`
    bool raycast(
        scope const(CellCoord)[] cells,
        in Vector3f origin,
        in Vector3f direction,
        float maxT,
        out T item,
        out float distance,
    )
    {
        bool hit;

        foreach(cell; cells)
        {
            auto tree = treeOf(cell);

            if(tree is null || tree.bvh is null)
                continue;

            size_t local;
            float t;

            if(tree.bvh.raycast(origin, direction, maxT, local, t) && (!hit || t < distance))
            {
                hit = true;
                item = cast(T) items[tree.items[local]];
                distance = t;
            }
        }

        return hit;
    }

    /// Culling tree of the cell, built once
    private CellTree* treeOf(CellCoord cell)
    {
        if(auto found = cell in cellTrees)
            return found;

        auto ids = cell in byCell;

        if(ids is null)
            return null;

        CellTree tree;

        foreach(index; *ids)
            if(hasBounds(itemBounds[index]))
                tree.items ~= index;

        if(tree.items.length)
        {
            Boxf[] boxes;
            boxes.reserve(tree.items.length);

            foreach(index; tree.items)
                boxes ~= itemBounds[index];

            tree.bvh = new BoxBvh;
            tree.bvh.build(boxes);
        }

        cellTrees[cell] = tree;

        return cell in cellTrees;
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

    /// Item placements in the cells, counting an item once per cell it touches
    size_t placementsIn(scope const(CellCoord)[] cells) const
    {
        size_t result;

        foreach(cell; cells)
            if(auto found = cell in byCell)
                result += found.length;

        return result;
    }

    size_t itemCount() const => items.length;

    size_t cellCount() const => byCell.length;

    /// Cell placements over all items; above `itemCount` when items cross borders
    size_t placementCount() const => placements;
}

unittest
{
    import std.algorithm: canFind;
    import dlib.math: scaleMatrix;

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

    // The cell tree answers the frustum and a ray
    auto query = new CellIndex!int(grid);
    query.insert(7, box(0, 0, 0));
    query.insert(8, box(50, 0, 0));
    query.insert(9, Boxf.init);

    const near = grid.of(Vector3f(0.5f, 0.5f, 0.5f));
    const far = grid.of(Vector3f(50.5f, 0.5f, 0.5f));
    const view = Vector3f(0.05f, 0.05f, 0.05f).scaleMatrix;

    const seen = query.visible([near], view);
    assert(seen.canFind(7));
    assert(seen.canFind(9), "an item without bounds stays visible");
    assert(!seen.canFind(8), "the far item is culled");

    int hit;
    float t;
    assert(query.raycast([far], Vector3f(40, 0.5f, 0.5f), Vector3f(1, 0, 0), 100, hit, t));
    assert(hit == 8);
}
