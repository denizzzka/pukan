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
    import pukan.graphics.g3d.cell_index: Bounded;
    import pukan.graphics.g3d.cells: CellGrid;
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

    auto tree = new SceneTree;
    scope(exit) tree.destroy;

    auto bounded = new Stub;
    bounded.box = Boxf(Vector3f(0, 0, 0), Vector3f(1, 1, 1));

    // A drawable that cannot bound itself is visible from every cell
    auto unbounded = new Stub;

    tree
        .addChild(Bone(mat: Vector3f(50, 0, 0).translationMatrix))
        .addChild(cast(DrawableByVulkan) bounded);
    tree.addChild(cast(DrawableByVulkan) unbounded);

    const grid = CellGrid(10);
    tree.rebuildCells(grid);

    bool foundBounded;
    bool foundUnbounded;

    foreach(item; tree.cells.collect([grid.of(Vector3f(50.5f, 0.5f, 0.5f))]))
    {
        if(item.drawable is bounded)
            foundBounded = true;
        else if(item.drawable is unbounded)
            foundUnbounded = true;
    }

    assert(foundBounded, "a drawable lands in the cell its transformed bounds touch");
    assert(foundUnbounded, "an unbounded drawable stays visible everywhere");

    // The cell at the origin holds only the unbounded drawable
    assert(tree.cells.collect([grid.of(Vector3f(0, 0, 0))]).length == 1);
}
