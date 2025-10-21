module pukan.primitives_tree.tree;

import pukan.primitives_tree: Payload, DrawablePrimitive, Bone;
import pukan.tree.drawable_tree: DrawableTreeBase = DrawableTree;
import pukan.vulkan.bindings;
import pukan.vulkan.commands: CommandPool;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.pipelines: GraphicsPipelineCfg;
import pukan.vulkan.renderpass: DrawableByVulkan;

/// This is a very unusual type of drawable object, added during engine
/// development for variety. You're unlikely to need it.
class PrimitivesTree : DrawableTreeBase!Payload, DrawableByVulkan
{
    import dlib.math;

    ~this()
    {
        forEachPrimitive((e) => e.destroy);
        forEachDrawablePayload((d) => d.destroy);
    }

    override void drawingBufferFilling(VkCommandBuffer buf, Matrix4f trans)
    {
        drawingBufferFillingRecursive(buf, GraphicsPipelineCfg.init, trans, root);
    }

    private void drawingBufferFillingRecursive(VkCommandBuffer buf, GraphicsPipelineCfg pipelineCfg, Matrix4x4f trans, Node curr)
    {
        // TODO: deduplicate code with DrawableTree.drawingBufferFillingRecursive ?

        if(curr.payload.type == typeid(DrawablePrimitive))
        {
            auto dr = curr.payload.peek!DrawablePrimitive;

            dr.drawingBufferFilling(buf, pipelineCfg, trans);
        }
        if(curr.payload.type == typeid(DrawableByVulkan))
        {
            auto dr = curr.payload.peek!DrawableByVulkan;

            dr.drawingBufferFilling(buf, trans);
        }
        else if(curr.payload.type == typeid(Bone))
        {
            trans *= curr.payload.peek!Bone.mat;
        }
        else if(curr.payload.type == typeid(GraphicsPipelineCfg))
        {
            pipelineCfg = *curr.payload.peek!GraphicsPipelineCfg;
        }

        foreach(ref c; curr.children)
            drawingBufferFillingRecursive(buf, pipelineCfg, trans, cast(Node) c);
    }

    private void forEachPrimitive(void delegate(DrawablePrimitive) dg)
    {
        root.traversal((node){
            auto n = cast(Node) node;

            if(n.payload.type == typeid(DrawablePrimitive))
                dg(*n.payload.peek!DrawablePrimitive);
        });
    }

    override void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        forEachPrimitive((pr){
            pr.uploadToGPUImmediate(device, commandPool, commandBuffer);
        });

        super.uploadToGPUImmediate(device, commandPool, commandBuffer);
    }

    //TODO: ditto
    override void refreshBuffers(VkCommandBuffer buf){}
}
