module pukan.primitives_tree;

import pukan.primitives_tree.mesh;
import pukan.scene: Vertex;
import pukan.vulkan.bindings;
import pukan.vulkan.renderpass: DrawableByVulkan;
import std.variant: Algebraic;
import dlib.math: Matrix4x4f;

alias Payload = Algebraic!(
    Bone,
    DrawableByVulkan,
    PrimitivesTree,
);

struct Node
{
    Node* parent;
    Node[] children;
    package Payload payload;
}

struct PipelineConfig
{
    VkPipeline graphicsPipeline;
    VkPipelineLayout pipelineLayout;
}

class PrimitivesTree
{
    PipelineConfig[2] pipelinesConfigs;
    Node root;

    void setPayload(T)(Node* node, VkPipeline graphicsPipeline,)
    {
    }
}

/// Represents the translation of an node relative to the ancestor bone node
//TODO: 4x3 should be enough
alias Bone = Matrix4x4f;
