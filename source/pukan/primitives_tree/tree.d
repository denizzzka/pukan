module pukan.primitives_tree.tree;

import pukan.primitives_tree;
import pukan.vulkan.bindings;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: TransferBuffer;
import pukan.vulkan.renderpass: DrawableByVulkan;

class PrimitivesTree //TODO: DrawableByVulkan
{
    import pukan.scene: Scene;

    PipelineConfig[] pipelinesConfig;
    Node root;

    this(Scene scene)
    {
        pipelinesConfig.length = scene.pipelineInfoCreators.length;

        foreach(i, ref cfg; pipelinesConfig)
        {
            cfg.graphicsPipeline = scene.graphicsPipelines.pipelines[i];
            cfg.pipelineLayout = scene.pipelineInfoCreators[i].pipelineLayout;
        }
    }

    void setPayload(ref Node node, DrawableByVulkan drawable, ubyte pipelineCfgIdx)
    in(pipelineCfgIdx < pipelinesConfig.length)
    {
        node.payload = Drawable(pipelineCfgIdx, drawable);
    }

    void forEachNode(void delegate(ref Node) dg) => root.traversal(dg);

    void drawingBufferFilling(VkCommandBuffer buf, VkDescriptorSet[] descriptorSets)
    {
        auto dr = root.payload.peek!Drawable;
        auto pcfg = pipelinesConfig[dr.pipelineCfgIdx];

        //FIXME: remove and use bone value
        import dlib.math: Matrix4f;
        auto noTrans = Matrix4f.identity;

        dr.drawingBufferFilling(
            buf,
            pcfg.graphicsPipeline,
            pcfg.pipelineLayout,
            descriptorSets,
            noTrans,
        );
    }
}
