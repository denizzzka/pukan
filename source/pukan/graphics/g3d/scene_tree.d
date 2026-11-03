module pukan.graphics.g3d.scene_tree;

import pukan.graphics.g3d.tree.drawable_tree: DrawableTree;
import pukan.graphics.g3d.primitives_tree: Bone;
import pukan.vulkan.renderpass: DrawableByVulkan;
import std.variant: Algebraic;

alias Payload = Algebraic!(
    Bone,
    DrawableByVulkan,
);

alias SceneTree = DrawableTree!Payload;

unittest
{
    import dlib.math: Matrix4x4f, scaleMatrix, translationMatrix, Vector3f;
    import pukan.graphics.common.misc: Boxf;
    import pukan.graphics.g3d.cell_index: Bounded, DrawItem, Part, PartDrawable, holdCells, releaseCells, uploadCells;
    import pukan.graphics.g3d.cells: CellCoord, CellGrid;
    import pukan.vulkan.bindings;
    import pukan.vulkan.commands: CommandPool;
    import pukan.vulkan.logical_device: LogicalDevice;
    import pukan.vulkan.renderpass: DrawPhase, DrawableByVulkan;

    static class Stub : DrawableByVulkan, Bounded
    {
        Boxf box;
        size_t drawn;

        void uploadToGPUImmediate(LogicalDevice, CommandPool, scope VkCommandBuffer) {}

        void refreshBuffers(VkCommandBuffer) {}

        void drawingBufferFilling(
            VkCommandBuffer,
            Matrix4x4f,
            VkDescriptorSet,
            DrawPhase = DrawPhase.surface,
        )
        {
            ++drawn;
        }

        Boxf localBounds() => box;

        Boxf cellBounds() => box;
    }

    /// Two parts 100 m apart, so one drawable lands in two cells
    static class Split : DrawableByVulkan, PartDrawable
    {
        size_t[] drawnKeys;
        Matrix4x4f[] drawnTrans;
        size_t[] loadedKeys;
        size_t[] releasedKeys;

        void uploadToGPUImmediate(LogicalDevice, CommandPool, scope VkCommandBuffer) {}

        void refreshBuffers(VkCommandBuffer) {}

        void drawingBufferFilling(
            VkCommandBuffer,
            Matrix4x4f,
            VkDescriptorSet,
            DrawPhase = DrawPhase.surface,
        ) {}

        void eachPart(scope void delegate(in Part part) dg)
        {
            const unit = Boxf(Vector3f(-1, -1, -1), Vector3f(1, 1, 1));

            dg(Part(unit, Vector3f(0, 0, 0).translationMatrix, 0));
            dg(Part(unit, Vector3f(100, 0, 0).translationMatrix, 1));
        }

        void holdParts(scope const(size_t)[] keys)
        {
            loadedKeys ~= keys;
        }

        void releaseParts(scope const(size_t)[] keys)
        {
            releasedKeys ~= keys;
        }

        size_t uploadParts(VkCommandBuffer, size_t budget) => 0;

        void drawParts(
            VkCommandBuffer,
            in Matrix4x4f trans,
            scope const(size_t)[] keys,
            VkDescriptorSet,
            DrawPhase,
        )
        {
            foreach(key; keys)
            {
                drawnKeys ~= key;
                drawnTrans ~= trans;
            }
        }
    }

    const grid = CellGrid(10);

    auto tree = new SceneTree;
    scope(exit) tree.destroy;

    auto bone = tree.addChild(Bone(mat: Vector3f(50, 0, 0).translationMatrix));

    auto bounded = new Stub;
    bounded.box = Boxf(Vector3f(0, 0, 0), Vector3f(1, 1, 1));
    bone.addChild(cast(DrawableByVulkan) bounded);

    auto split = new Split;
    bone.addChild(cast(DrawableByVulkan) split);

    // A drawable that cannot bound itself is visible from every cell
    auto unbounded = new Stub;
    tree.addChild(cast(DrawableByVulkan) unbounded);

    // A wide drawable sits in two cells but is recorded once as a whole
    auto wide = new Stub;
    wide.box = Boxf(Vector3f(-10, 0, 0), Vector3f(19, 1, 1));
    tree.addChild(cast(DrawableByVulkan) wide);

    tree.rebuildCells(grid);

    DrawItem[] itemsAt(CellCoord cell) => tree.cells.collect([cell]);

    bool holds(DrawItem[] items, DrawableByVulkan drawable)
    {
        foreach(item; items)
            if(item.drawable is drawable)
                return true;

        return false;
    }

    // The bounded drawable sits in the cell its transformed bounds touch
    assert(holds(itemsAt(grid.of(Vector3f(50.5f, 0.5f, 0.5f))), bounded));

    // A split drawable places its parts under the same node transform
    assert(holds(itemsAt(grid.of(Vector3f(50.5f, 0.5f, 0.5f))), split), "the first part lands 50 m out");
    assert(holds(itemsAt(grid.of(Vector3f(150.5f, 0.5f, 0.5f))), split), "the second part lands 150 m out");
    assert(!holds(itemsAt(grid.of(Vector3f(100.5f, 0.5f, 0.5f))), split),
        "the split drawable holds no part at 100 m");

    // Parts keep the key their drawable reported
    foreach(item; itemsAt(grid.of(Vector3f(150.5f, 0.5f, 0.5f))))
        if(item.drawable is split)
        {
            assert(item.part == 1);
            assert(item.world.a14 == 50, "the item carries the transform of the drawable");
            assert(item.bounds.min.x == 149 && item.bounds.max.x == 151, "the part stays in its bounds");
        }

    // A view records the parts of its cells: one part per split item, and the
    // whole drawables once, even when a cell set holds several of their items
    const cells = [
        grid.of(Vector3f(0.5f, 0.5f, 0.5f)),
        grid.of(Vector3f(10.5f, 0.5f, 0.5f)),
        grid.of(Vector3f(50.5f, 0.5f, 0.5f)),
    ];

    // A view that fits the whole test level, so nothing is culled by distance
    import std.math: isClose;

    const view = Vector3f(0.005f, 0.005f, 0.005f).scaleMatrix;

    tree.drawCells(VkCommandBuffer.init, view, cells, VkDescriptorSet.init);

    assert(split.drawnKeys.length == 1, "one split part is in those cells");
    assert(split.drawnKeys[0] == 0);
    assert(isClose(split.drawnTrans[0].a14, 0.25f, 1e-5f, 1e-5f), "the drawable transform applies");

    assert(bounded.drawn == 1, "a bounded drawable is recorded once");
    assert(wide.drawn == 1, "a drawable in two cells is not recorded twice");
    assert(unbounded.drawn == 1);

    // The index answers the frustum: parts outside it are not recorded
    split.drawnKeys = null;
    wide.drawn = 0;
    bounded.drawn = 0;
    unbounded.drawn = 0;

    tree.drawCells(VkCommandBuffer.init, Vector3f(1000, 0, 0).translationMatrix, cells, VkDescriptorSet.init);

    assert(split.drawnKeys.length == 0, "a part outside the frustum is not recorded");
    assert(wide.drawn == 0);
    assert(bounded.drawn == 0);
    assert(unbounded.drawn == 1, "a drawable without bounds stays visible");

    // Loading and releasing the cells group parts the same way
    const far = grid.of(Vector3f(150.5f, 0.5f, 0.5f));

    holdCells(tree.cells, [far]);
    assert(split.loadedKeys == [1]);

    releaseCells(tree.cells, [far]);
    assert(split.releasedKeys == [1]);
}
