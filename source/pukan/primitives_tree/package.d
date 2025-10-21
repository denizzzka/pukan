module pukan.primitives_tree;

import pukan;
public import pukan.primitives_tree.factory: PrimitivesFactory;
import pukan.vulkan.bindings;
import pukan.vulkan.pipelines: GraphicsPipelineCfg;
import pukan.vulkan.renderpass: DrawableByVulkan;
import std.variant: Algebraic;
import dlib.math: Matrix4x4f;

alias Payload = Algebraic!(
    Bone,
    DrawableByVulkan,
    GraphicsPipelineCfg, // switches pipeline for DrawablePrimitive children nodes
    DrawablePrimitive,
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

interface DrawablePrimitive
{
    void uploadToGPUImmediate(LogicalDevice, CommandPool, scope VkCommandBuffer);
    void drawingBufferFilling(VkCommandBuffer, GraphicsPipelineCfg, Matrix4x4f); //const
}
