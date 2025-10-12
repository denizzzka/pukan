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

class DrawableTree : PrimitivesTree //TODO:, DrawableByVulkan
{
    import pukan.scene: Scene;

    void setPayload(ref Node node, DrawableByVulkan drawable, GraphicsPipelineCfg cfg)
    {
        node.addChildNode(cfg).addChildNode(drawable);
    }

    import dlib.math;

    void drawingBufferFilling(VkCommandBuffer buf, VkDescriptorSet[] descriptorSets)
    {
        drawingBufferFilling(buf, descriptorSets, root, Matrix4f.identity, null);
    }

    private void drawingBufferFilling(VkCommandBuffer buf, VkDescriptorSet[] descriptorSets, ref Node curr, Matrix4x4f trans, GraphicsPipelineCfg* pipelineCfg)
    {
        if(curr.payload.type == typeid(Bone))
        {
            trans *= curr.payload.peek!Bone.mat;
        }
        else if(curr.payload.type == typeid(GraphicsPipelineCfg))
        {
            pipelineCfg = curr.payload.peek!GraphicsPipelineCfg;
        }
        else if(curr.payload.type == typeid(DrawableByVulkan))
        {
            auto dr = curr.payload.peek!DrawableByVulkan;

            dr.drawingBufferFilling(
                buf,
                *pipelineCfg,
                descriptorSets,
                trans,
            );
        }

        foreach(ref c; curr.children)
            drawingBufferFilling(buf, descriptorSets, c, trans, pipelineCfg);
    }
}
