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
    import dlib.math: Matrix4x4f, translationMatrix, Vector3f;
    import pukan.graphics.common.misc: Boxf;
    import pukan.graphics.g3d.cell_index: Bounded, DrawItem, Spatial;
    import pukan.graphics.g3d.cells: CellCoord, CellGrid;
    import pukan.vulkan.bindings;
    import pukan.vulkan.commands: CommandPool;
    import pukan.vulkan.logical_device: LogicalDevice;
    import pukan.vulkan.renderpass: DrawPhase, DrawableByVulkan;

    static class Stub : DrawableByVulkan, Bounded
    {
        Boxf box;

        void uploadToGPUImmediate(LogicalDevice, CommandPool, scope VkCommandBuffer) {}

        void refreshBuffers(VkCommandBuffer) {}

        void drawingBufferFilling(
            VkCommandBuffer,
            Matrix4x4f,
            VkDescriptorSet,
            DrawPhase = DrawPhase.surface,
        ) {}

        Boxf localBounds() => box;

        Boxf cellBounds() => box;
    }

    /// Two parts 100 m apart, so one drawable lands in two cells
    static class Split : DrawableByVulkan, Spatial
    {
        void uploadToGPUImmediate(LogicalDevice, CommandPool, scope VkCommandBuffer) {}

        void refreshBuffers(VkCommandBuffer) {}

        void drawingBufferFilling(
            VkCommandBuffer,
            Matrix4x4f,
            VkDescriptorSet,
            DrawPhase = DrawPhase.surface,
        ) {}

        void eachPart(scope void delegate(in Boxf bounds, in Matrix4x4f local) dg)
        {
            const unit = Boxf(Vector3f(-1, -1, -1), Vector3f(1, 1, 1));

            dg(unit, Vector3f(0, 0, 0).translationMatrix);
            dg(unit, Vector3f(100, 0, 0).translationMatrix);
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
    auto near = itemsAt(grid.of(Vector3f(50.5f, 0.5f, 0.5f)));
    auto far = itemsAt(grid.of(Vector3f(150.5f, 0.5f, 0.5f)));

    assert(holds(near, split), "the first part lands 50 m out");
    assert(holds(far, split), "the second part lands 150 m out");
    assert(!holds(itemsAt(grid.of(Vector3f(100.5f, 0.5f, 0.5f))), split),
        "the split drawable holds no part at 100 m");

    foreach(item; far)
        if(item.drawable is split)
            assert(item.world.a14 == 150, "the part transform carries the node transform");

    // One unbounded drawable, and nothing else, is visible everywhere
    assert(tree.cells.alwaysVisible.length == 1);
    assert(tree.cells.alwaysVisible[0].drawable is unbounded);

    // The cell at the origin holds only the always visible drawable
    assert(itemsAt(grid.of(Vector3f(0, 0, 0))).length == 1);
}
