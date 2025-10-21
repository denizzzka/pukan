module pukan.tree.drawable_tree;

import dlib.math;
import pukan.tree: BaseNode = Node;
import pukan.vulkan.bindings;
import pukan.vulkan.commands: CommandPool;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.primitives_tree: Bone;
import pukan.vulkan.renderpass: DrawableByVulkan;

class DrawableTree(Payload) : DrawableByVulkan
{
    static class Node : BaseNode
    {
        Payload payload;
        alias this = payload;

        Node addChild(DrawableByVulkan val) => addChild!DrawableByVulkan(cast(DrawableByVulkan) val);

        Node addChild(T)(T val)
        if(!is(T == Node))
        {
            auto n = new Node;
            n.payload = Payload(val);

            return addChild(n);
        }

        Node addChild(Node n) => cast(Node) super.addChildNode(n).front;
    }

    Node root;
    alias this = root;

    this()
    {
        root = new Node;
    }

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
        drawingBufferFillingRecursive(buf, trans, root);
    }

    private void drawingBufferFillingRecursive(VkCommandBuffer buf, Matrix4x4f trans, Node curr)
    {
        if(curr.payload.type == typeid(DrawableByVulkan))
        {
            auto dr = curr.payload.peek!DrawableByVulkan;

            dr.drawingBufferFilling(buf, trans);
        }
        else if(curr.payload.type == typeid(Bone))
        {
            trans *= curr.payload.peek!Bone.mat;
        }

        foreach(ref c; curr.children)
            drawingBufferFillingRecursive(buf, trans, cast(Node) c);
    }
}
