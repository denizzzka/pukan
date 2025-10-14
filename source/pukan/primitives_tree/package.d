module pukan.primitives_tree;

import pukan.primitives_tree.mesh;
import pukan.primitives_tree.tree: PrimitivesTree;
import pukan.scene: Vertex;
import pukan.vulkan.bindings;
import pukan.vulkan.pipelines: GraphicsPipelineCfg;
import pukan.vulkan.renderpass: DrawableByVulkan;
import std.container.slist;
import std.variant: Algebraic;
import dlib.math: Matrix4x4f;

alias Payload = Algebraic!(
    Bone,
    GraphicsPipelineCfg, // switches pipeline for children nodes
    DrawableByVulkan,
);

alias Node = NodeT!Payload;

struct NodeT(Payload)
{
    //TODO: unused, remove?
    NodeT* parent;
    SList!(NodeT*) children;
    /*package*/ Payload payload;

    NodeT* addChildNode()
    {
        auto c = new NodeT;
        c.parent = &this;

        children.insert(c);

        return c;
    }

    auto addChildNode(DrawableByVulkan payload)
    {
        return addChildNode!DrawableByVulkan(payload);
    }

    auto addChildNode(T)(T payload)
    {
        auto n = addChildNode();
        n.payload = payload;

        return n;
    }

    package void traversal(void delegate(ref NodeT) dg)
    {
        dg(this);

        foreach(ref c; children)
            c.traversal(dg);
    }
}

/// Represents the translation of an node relative to the ancestor bone node
struct Bone
{
    //TODO: 4x3 should be enough
    //TODO: init value Matrix4x4f.identity
    Matrix4x4f mat;
    alias this = mat;

    uint translationBufferIdx;
}

struct PrimitivesFactory(T)
{
    import pukan.vulkan;
    import shaders = pukan.vulkan.shaders;
    import pukan.vulkan.frame_builder;

    LogicalDevice device;
    private PoolAndLayoutInfo poolAndLayout;
    GraphicsPipelineCfg graphicsPipelineCfg;

    this(LogicalDevice device, ShaderInfo[] shaderStages, RenderPass renderPass)
    {
        this.device = device;

        auto layoutBindings = shaders.createLayoutBinding(shaderStages);
        poolAndLayout = device.createDescriptorPool(layoutBindings);

        auto pipelineInfoCreator = new DefaultGraphicsPipelineInfoCreator!Vertex(device, [poolAndLayout.descriptorSetLayout], shaderStages, renderPass);
        graphicsPipelineCfg.pipelineLayout = pipelineInfoCreator.pipelineLayout;

        auto pipelineCreateInfo = pipelineInfoCreator.pipelineCreateInfo;
        graphicsPipelineCfg.graphicsPipeline = device.createGraphicsPipelines([pipelineCreateInfo])[0];
    }

    auto create(CTOR_ARGS...)(FrameBuilder frameBuilder, CTOR_ARGS args)
    {
        assert(device);
        auto descriptorsSet = device.allocateDescriptorSets(poolAndLayout, 1);

        auto r = new T(descriptorsSet, args);
        r.updateDescriptorSet(device, frameBuilder);

        return r;
    }
}
