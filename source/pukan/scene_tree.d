module pukan.scene_tree;

import dlib.math;
import pukan.tree: BaseNode = Node;
import pukan.vulkan.bindings;
import pukan.vulkan.commands: CommandPool;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.primitives_tree: Bone;
import pukan.vulkan.renderpass: DrawableByVulkan;
import std.variant: Algebraic;

alias Payload = Algebraic!(
    Bone,
    DrawableByVulkan,
);

class Node : BaseNode
{
    Payload payload;
    alias this = payload;
}

class SceneTree : DrawableByVulkan
{
    Node root;

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

    void refreshBuffers(VkCommandBuffer buf)
    {
        //TODO: implement?
    }

    import pukan.vulkan.pipelines: GraphicsPipelineCfg;
    void drawingBufferFilling(VkCommandBuffer buf, GraphicsPipelineCfg pipelineCfg, Matrix4f trans)
    {
        assert(false, "remove this method");
    }

    void drawingBufferFilling(VkCommandBuffer buf, Matrix4f trans)
    {
        drawingBufferFilling(buf, trans);
    }

    private void drawingBufferFillingRecursive(VkCommandBuffer buf, Matrix4x4f trans, Node curr)
    {
        if(curr.payload.type == typeid(DrawableByVulkan))
        {
            auto dr = curr.payload.peek!DrawableByVulkan;

            dr.drawingBufferFilling(
                buf,
                GraphicsPipelineCfg.init, //FIXME: remove
                trans,
            );
        }
        else if(curr.payload.type == typeid(Bone))
        {
            trans *= curr.payload.peek!Bone.mat;
        }

        foreach(ref c; curr.children)
            drawingBufferFillingRecursive(buf, trans, cast(Node) c);
    }
}
