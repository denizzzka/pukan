module pukan.gltf.pipelines;

import pukan.vulkan.pipelines: GraphicsPipelineCfg;

struct GltfPipelineVariants
{
    GraphicsPipelineCfg opaque;
    GraphicsPipelineCfg doubleSided;
    GraphicsPipelineCfg blend;
    GraphicsPipelineCfg doubleSidedBlend;
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

/// Whether transmissive draws are collected into their own pass; off while the
/// colour behind them cannot be copied, as in stereo
bool transmissionPass = true;

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
    GltfPipelineVariants lit;
    GltfPipelineVariants unlit;
}

struct GltfPipelines
{
    GltfModePipelines skinned;
    GltfModePipelines unskinned;
}
