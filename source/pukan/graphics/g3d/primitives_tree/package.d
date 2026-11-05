module pukan.graphics.g3d.primitives_tree;

import pukan;
public import pukan.graphics.g3d.primitives_tree.factory: PrimitivesFactory;
public import pukan.graphics.g3d.primitives_tree.lines: LineInstance, LineRenderer;
import pukan.vulkan.bindings;
import pukan.vulkan.pipelines: GraphicsPipelineCfg;
import pukan.vulkan.renderpass: DrawableByVulkan;
import std.variant: Algebraic;
import dlib.math: Matrix4x4f;

/// Pipeline a branch uses while a shadow map is the target
struct ShadowPipelineCfg
{
    GraphicsPipelineCfg cfg;
}

alias Payload = Algebraic!(
    Bone,
    DrawableByVulkan,
    GraphicsPipelineCfg, // switches pipeline for DrawablePrimitive children nodes
    ShadowPipelineCfg,   // switches the depth-only pipeline of the same nodes
    DrawablePrimitive,
);

/// Represents the translation of an node relative to the ancestor bone node
//TODO: move to pukan.graphics.g3d.tree
struct Bone
{
    //TODO: 4x3 should be enough
    //TODO: init value Matrix4x4f.identity
    Matrix4x4f mat;
    alias this = mat;

    uint translationBufferIdx;
}

interface DrawablePrimitive
{
    void uploadToGPUImmediate(LogicalDevice, CommandPool, scope VkCommandBuffer);
    void drawingBufferFilling(VkCommandBuffer, GraphicsPipelineCfg, Matrix4x4f, VkDescriptorSet); //const

    /// Records the primitive into a shadow map, binding no material
    void drawingShadow(VkCommandBuffer, GraphicsPipelineCfg, Matrix4x4f);
}
