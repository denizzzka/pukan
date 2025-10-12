module pukan.primitives_tree.tree;

import pukan.primitives_tree;
import pukan.vulkan.bindings;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: TransferBuffer;
import pukan.vulkan.renderpass: DrawableByVulkan, GraphicsPipelineCfg;

class PrimitivesTree //TODO: DrawableByVulkan
{
    import pukan.scene: Scene;

    GraphicsPipelineCfg[] pipelinesConfig;
    Node root;

    this(Scene scene)
    {
        pipelinesConfig.length = scene.dbl.length;

        foreach(i, ref cfg; pipelinesConfig)
            cfg = scene.dbl[i].graphicsPipelineCfg;
    }

    void setPayload(ref Node node, DrawableByVulkan drawable, ubyte pipelineCfgIdx)
    in(pipelineCfgIdx < pipelinesConfig.length)
    {
        node.payload = Drawable(pipelineCfgIdx, drawable);
    }

    void forEachNode(void delegate(ref Node) dg) => root.traversal(dg);

    import dlib.math;

    void drawingBufferFilling(VkCommandBuffer buf, VkDescriptorSet[] descriptorSets)
    {
        drawingBufferFilling(buf, descriptorSets, root, Matrix4f.identity);
    }

    private void drawingBufferFilling(VkCommandBuffer buf, VkDescriptorSet[] descriptorSets, ref Node curr, Matrix4x4f trans)
    {
        if(curr.payload.type == typeid(Bone))
        {
            trans *= curr.payload.peek!Bone.mat;
        }
        else if(curr.payload.type == typeid(Drawable))
        {
            auto dr = curr.payload.peek!Drawable;
            auto pcfg = pipelinesConfig[dr.pipelineCfgIdx];

            dr.drawingBufferFilling(
                buf,
                pcfg.graphicsPipeline,
                pcfg.pipelineLayout,
                descriptorSets,
                trans,
            );
        }

        foreach(ref c; curr.children)
            drawingBufferFilling(buf, descriptorSets, c, trans);
    }
}
