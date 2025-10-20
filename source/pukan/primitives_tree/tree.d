module pukan.primitives_tree.tree;

import pukan.primitives_tree: Payload, Bone;
import pukan.tree.drawable_tree: DrawableTreeBase = DrawableTree;
import pukan.vulkan.bindings;
import pukan.vulkan.commands: CommandPool;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: TransferBuffer;
import pukan.vulkan.pipelines: GraphicsPipelineCfg;
import pukan.vulkan.renderpass: DrawableByVulkan;

class PrimitivesTree : DrawableTreeBase!Payload, DrawableByVulkan
{
    import dlib.math;

    ~this()
    {
        forEachDrawablePayload((d) => d.destroy);
    }

    override void drawingBufferFilling(VkCommandBuffer buf, Matrix4f trans)
    {
        drawingBufferFillingRecursive(buf, GraphicsPipelineCfg.init, trans, root);
    }

    private void drawingBufferFillingRecursive(VkCommandBuffer buf, GraphicsPipelineCfg pipelineCfg, Matrix4x4f trans, Node curr)
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

        foreach(ref c; curr.children)
            drawingBufferFillingRecursive(buf, pipelineCfg, trans, cast(Node) c);
    }
}
