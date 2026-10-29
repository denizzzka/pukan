module pukan.gltf.pipelines;

import pukan.vulkan.pipelines: GraphicsPipelineCfg;

struct GltfPipelineVariants
{
    GraphicsPipelineCfg opaque;
    GraphicsPipelineCfg doubleSided;
    GraphicsPipelineCfg blend;
    GraphicsPipelineCfg doubleSidedBlend;
    GraphicsPipelineCfg oit;
    GraphicsPipelineCfg doubleSidedOit;
}

/// Lighting of the scene, chosen at draw time
enum LightingMode
{
    ibl,
    analytic,
    none,
    unlit,
}

/// Render setting, read by the drawables on every draw
LightingMode lightingMode = LightingMode.ibl;

/// Draw-time mirror of `Scene.transmissionPassEnabled`: transmissive draws go to
/// their own pass only while that pass runs
bool transmissionPass = true;

/// Draw-time mirror of `Scene.oitEnabled`: blended draws store their fragments
/// for the resolve pass instead of blending in place
bool oitPass = true;

struct GltfSkyPipelines
{
    GltfPipelineVariants ibl;
    GltfPipelineVariants analytic;
    GltfPipelineVariants none;
}

/// One shader per material mode; the mode is fixed when the file is loaded
struct GltfModePipelines
{
    GltfSkyPipelines pbr;
    GltfSkyPipelines pbrCore;
    GltfPipelineVariants lit;
    GltfPipelineVariants unlit;
}

struct GltfPipelines
{
    GltfModePipelines skinned;
    GltfModePipelines unskinned;
    GraphicsPipelineCfg skinnedShadow;
    GraphicsPipelineCfg unskinnedShadow;
}
