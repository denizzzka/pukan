module pukan.pbr.pipelines;

import pukan.vulkan.pipelines: GraphicsPipelineCfg;

struct PbrPipelineVariants
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

/// Draw-time switch: every surface uses the plain lit pipeline as opaque
bool plainShading;

struct PbrSkyPipelines
{
    PbrPipelineVariants ibl;
    PbrPipelineVariants analytic;
    PbrPipelineVariants none;
}

/// One shader per material mode; the mode is fixed when the file is loaded
struct PbrModePipelines
{
    PbrSkyPipelines pbr;
    PbrSkyPipelines pbrCore;
    PbrPipelineVariants lit;
    PbrPipelineVariants unlit;
}

struct PbrPipelines
{
    PbrModePipelines skinned;
    PbrModePipelines unskinned;
    GraphicsPipelineCfg skinnedShadow;
    GraphicsPipelineCfg unskinnedShadow;
}
