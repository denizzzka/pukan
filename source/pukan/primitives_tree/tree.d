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

    void drawingBufferFilling(VkCommandBuffer buf, VkDescriptorSet[] descriptorSets)
    {
        //~ auto pipelineCfg = GraphicsPipelineCfg.init;

        drawingBufferFilling(buf, GraphicsPipelineCfg.init, descriptorSets, Matrix4f.identity);
    }

    void drawingBufferFilling(VkCommandBuffer buf, GraphicsPipelineCfg pipelineCfg, VkDescriptorSet[] descriptorSets, Matrix4x4f trans)
    {
        drawingBufferFilling(buf, pipelineCfg, descriptorSets, trans, root);
    }

    private void drawingBufferFilling(VkCommandBuffer buf, GraphicsPipelineCfg pipelineCfg, VkDescriptorSet[] descriptorSets, Matrix4x4f trans, ref Node curr)
    {
        if(curr.payload.type == typeid(DrawableByVulkan))
        {
            auto dr = curr.payload.peek!DrawableByVulkan;

            dr.drawingBufferFilling(
                buf,
                pipelineCfg,
                descriptorSets,
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
            drawingBufferFilling(buf, pipelineCfg, descriptorSets, trans, c);
    }
}
