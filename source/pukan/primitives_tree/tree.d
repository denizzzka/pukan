module pukan.primitives_tree.tree;

import pukan.primitives_tree;
import pukan.vulkan.bindings;
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

        dr.drawingBufferFilling(
            buf,
            pcfg.graphicsPipeline,
            pcfg.pipelineLayout,
            descriptorSets,
        );
    }
}
