module pukan.primitives_tree.tree;

import pukan.primitives_tree;
import pukan.vulkan.bindings;
import pukan.vulkan.commands: CommandPool;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: TransferBuffer;
import pukan.vulkan.pipelines: GraphicsPipelineCfg;
import pukan.vulkan.renderpass: DrawableByVulkan;

class TreeT(NodeT)
{
    NodeT root;

    void forEachNode(void delegate(ref NodeT) dg) => root.traversal(dg);
}

alias PrimitivesTree = TreeT!Node;

class DrawableTree : PrimitivesTree, DrawableByVulkan
{
    import dlib.math;

    ~this()
    {
        forEachDrawablePayload((d) => d.destroy);
    }

    void forEachDrawablePayload(void delegate(DrawableByVulkan) dg)
    {
        forEachNode((n){
            if(n.payload.type == typeid(DrawableByVulkan))
                dg(*n.payload.peek!DrawableByVulkan);
        });
    }

    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        forEachDrawablePayload((d) => d.uploadToGPUImmediate(device, commandPool, commandBuffer));
    }

    void refreshBuffers(VkCommandBuffer buf)
    {
    }

    //TODO: remove? Translation now is mandatory arg for start of the scene rendering
    void startDrawTree(VkCommandBuffer buf)
    {
        drawingBufferFilling(buf, GraphicsPipelineCfg.init, Matrix4f.identity);
    }

    void drawingBufferFilling(VkCommandBuffer buf, Matrix4f trans)
    {
        drawingBufferFilling(buf, GraphicsPipelineCfg.init, trans);
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
        else if(curr.payload.type == typeid(GraphicsPipelineCfg)) //TODO: not needed for glTF
        {
            pipelineCfg = *curr.payload.peek!GraphicsPipelineCfg;
        }

        //FIXME:
        //~ foreach(ref c; curr.children)
            //~ drawingBufferFilling(buf, pipelineCfg, trans, c);
    }
}
