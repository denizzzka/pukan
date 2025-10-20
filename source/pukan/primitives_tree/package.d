module pukan.primitives_tree;

import pukan.primitives_tree.mesh;
import pukan.primitives_tree.tree: PrimitivesTree;
public import pukan.primitives_tree.factory: PrimitivesFactory;
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

/// Represents the translation of an node relative to the ancestor bone node
struct Bone
{
    //TODO: 4x3 should be enough
    //TODO: init value Matrix4x4f.identity
    Matrix4x4f mat;
    alias this = mat;

    uint translationBufferIdx;
}
