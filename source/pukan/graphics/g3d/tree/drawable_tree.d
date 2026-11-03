module pukan.graphics.g3d.tree.drawable_tree;

import dlib.math;
import std.algorithm: sort;
import pukan.graphics.common.misc: Boxf, hasBounds, transformAabb;
import pukan.graphics.g3d.cell_index: Bounded, CellIndex, DrawItem;
import pukan.graphics.g3d.cells: CellGrid;
import pukan.graphics.g3d.tree: BaseNode = Node;
import pukan.vulkan.bindings;
import pukan.vulkan.commands: CommandPool;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.graphics.g3d.primitives_tree: Bone;
import pukan.vulkan.renderpass: Blended, DrawableByVulkan, DrawPhase, PipelineWarmup;

class DrawableTree(Payload) : DrawableByVulkan, PipelineWarmup
{
    static class Node : BaseNode
    {
        Payload payload;
        alias this = payload;

        Node addChild(DrawableByVulkan val) => addChild!DrawableByVulkan(cast(DrawableByVulkan) val);

        Node addChild(T)(T val)
        if(!is(T == Node))
        {
            auto n = new Node;
            n.payload = Payload(val);

            return addChild(n);
        }

        Node addChild(Node n) => cast(Node) super.addChildNode(n).front;
    }

    Node root;
    alias this = root;

    private CellIndex!DrawItem cellIndex;

    this()
    {
        root = new Node;
    }

    /// Partitions the tree into cells; rebuild when a drawable crosses a border
    void rebuildCells(CellGrid grid)
    {
        auto index = new CellIndex!DrawItem(grid);

        void walk(Node node, Matrix4x4f trans)
        {
            if(node.payload.type == typeid(DrawableByVulkan))
            {
                auto drawable = *node.payload.peek!DrawableByVulkan;
                auto bounded = cast(Bounded) drawable;
                const local = bounded is null ? Boxf.init : bounded.cellBounds;

                index.insert(
                    DrawItem(drawable, trans),
                    hasBounds(local) ? transformAabb(local, trans) : Boxf.init,
                );
            }
            else if(node.payload.type == typeid(Bone))
                trans *= node.payload.peek!Bone.mat;

            foreach(ref c; node.children)
                walk(cast(Node) c, trans);
        }

        walk(root, Matrix4x4f.identity);

        cellIndex = index;
    }

    /// Cells of the last `rebuildCells`; null before the first one
    CellIndex!DrawItem cells() => cellIndex;

    ~this()
    {
        forEachDrawablePayload((d) => d.destroy);
    }

    void forEachDrawablePayload(void delegate(DrawableByVulkan) dg)
    {
        root.traversal((node){
            auto n = cast(Node) node;

            if(n.payload.type == typeid(DrawableByVulkan))
                dg(*n.payload.peek!DrawableByVulkan);
        });
    }

    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        forEachDrawablePayload((d) => d.uploadToGPUImmediate(device, commandPool, commandBuffer));
    }

    void warmPipelines(bool shadows)
    {
        forEachDrawablePayload((d) {
            if(auto warm = cast(PipelineWarmup) d)
                warm.warmPipelines(shadows);
        });
    }

    void refreshBuffers(VkCommandBuffer buf)
    {
        //TODO: implement?
    }

    import pukan.vulkan.pipelines: GraphicsPipelineCfg;

    private struct Pending
    {
        DrawableByVulkan drawable;
        Matrix4x4f trans;
        float depth;
    }

    void drawingBufferFilling(
        VkCommandBuffer buf,
        Matrix4f trans,
        VkDescriptorSet frameSet,
        DrawPhase phase = DrawPhase.surface,
    )
    {
        Pending[] blended;
        drawingBufferFillingRecursive(buf, trans, frameSet, root, blended, phase);

        blended.sort!((a, b) => a.depth > b.depth);

        foreach(pending; blended)
            pending.drawable.drawingBufferFilling(buf, pending.trans, frameSet, phase);
    }

    private void drawingBufferFillingRecursive(
        VkCommandBuffer buf,
        Matrix4x4f trans,
        VkDescriptorSet frameSet,
        Node curr,
        ref Pending[] blended,
        DrawPhase phase,
    )
    {
        if(curr.payload.type == typeid(DrawableByVulkan))
        {
            auto dr = *curr.payload.peek!DrawableByVulkan;

            auto blendedDrawable = cast(Blended) dr;

            if(blendedDrawable !is null && blendedDrawable.isBlended)
            {
                const clip = Vector4f(0, 0, 0, 1) * trans;
                blended ~= Pending(dr, trans, clip.w);
            }
            // A drawable without blended meshes has nothing to add in that phase
            else if(phase != DrawPhase.blended)
                dr.drawingBufferFilling(buf, trans, frameSet, phase);
        }
        else if(curr.payload.type == typeid(Bone))
        {
            trans *= curr.payload.peek!Bone.mat;
        }

        foreach(ref c; curr.children)
            drawingBufferFillingRecursive(buf, trans, frameSet, cast(Node) c, blended, phase);
    }
}
