module pukan.primitives_tree;

import pukan.primitives_tree.mesh;
import pukan.scene: Vertex;
import pukan.vulkan.bindings;
import pukan.vulkan.renderpass: DrawableByVulkan;
import std.variant: Algebraic;
import dlib.math: Matrix4x4f;

struct Drawable
{
    ubyte pipelineCfgIdx;

    DrawableByVulkan drawable;
    alias this = drawable;
}

alias Payload = Algebraic!(
    Bone,
    Drawable,
    PrimitivesTree,
);

struct Node
{
    Node* parent;
    Node[] children;
    package Payload payload;

    private void traversal(void delegate(ref Node) dg)
    {
        dg(this);

        foreach(ref c; children)
            c.traversal(dg);
    }
}

struct PipelineConfig
{
    VkPipeline graphicsPipeline;
    VkPipelineLayout pipelineLayout;
}

class PrimitivesTree
{
    PipelineConfig[2] pipelinesConfig;
    Node root;

    void setPayload(ref Node node, DrawableByVulkan drawable, ubyte pipelineCfgIdx)
    in(pipelineCfgIdx < pipelinesConfig.length)
    {
        node.payload = Drawable(pipelineCfgIdx, drawable);
    }

    void forEachNode(void delegate(ref Node) dg) => root.traversal(dg);
}

/// Represents the translation of an node relative to the ancestor bone node
//TODO: 4x3 should be enough
alias Bone = Matrix4x4f;
