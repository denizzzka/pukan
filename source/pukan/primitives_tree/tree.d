module pukan.primitives_tree.tree;

import pukan.primitives_tree;
import pukan.vulkan.bindings;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: TransferBuffer;
import pukan.vulkan.pipelines: GraphicsPipelineCfg;
import pukan.vulkan.renderpass: DrawableByVulkan;

class PrimitivesTree
{
    Node root;

    void forEachNode(void delegate(ref Node) dg) => root.traversal(dg);
}

class DrawableTree : PrimitivesTree, DrawableByVulkan
{
    import dlib.math;

    ~this()
    {
        forEachNode((n){
            if(n.payload.type == typeid(DrawableByVulkan))
                n.payload.destroy;
        });
    }

    void drawingBufferFilling(VkCommandBuffer buf)
    {
        drawingBufferFilling(buf, GraphicsPipelineCfg.init, Matrix4f.identity);
    }

    void drawingBufferFilling(VkCommandBuffer buf, GraphicsPipelineCfg pipelineCfg, Matrix4x4f trans)
    {
        drawingBufferFilling(buf, pipelineCfg, trans, root);
    }

    private void drawingBufferFilling(VkCommandBuffer buf, GraphicsPipelineCfg pipelineCfg, Matrix4x4f trans, ref Node curr)
    {
        if(curr.payload.type == typeid(DrawableByVulkan))
        {
            auto dr = curr.payload.peek!DrawableByVulkan;

            dr.drawingBufferFilling(
                buf,
                pipelineCfg,
                trans,
            );
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
            drawingBufferFilling(buf, pipelineCfg, trans, c);
    }
}
