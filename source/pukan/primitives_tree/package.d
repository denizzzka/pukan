module pukan.primitives_tree;

import pukan.primitives_tree.mesh;
import pukan.primitives_tree.tree: PrimitivesTree;
import pukan.scene: Vertex;
import pukan.vulkan.bindings;
import pukan.vulkan.pipelines: GraphicsPipelineCfg;
import pukan.vulkan.renderpass: DrawableByVulkan;
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
    Node* parent;
    Node[] children;
    /*package*/ Payload payload;

    Node* addChildNode()
    {
        children.length++;
        auto c = &children[$-1];
        c.parent = &this;

        return c;
    }

    auto addChildNode(T)(T payload)
    {
        auto n = addChildNode();
        n.payload = payload;

        return n;
    }

    package void traversal(void delegate(ref Node) dg)
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
    Matrix4x4f mat;
    alias this = mat;

    uint translationBufferIdx;
}
