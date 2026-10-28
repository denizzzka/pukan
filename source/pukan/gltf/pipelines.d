module pukan.gltf.pipelines;

import pukan.vulkan.pipelines: GraphicsPipelineCfg;

struct GltfPipelineVariants
{
    GraphicsPipelineCfg opaque;
    GraphicsPipelineCfg doubleSided;
    GraphicsPipelineCfg blend;
    GraphicsPipelineCfg doubleSidedBlend;
}

/// One shader per sky, chosen at draw time
enum SkyMode
{
    ibl,
    analytic,
    none,
}

/// Render setting, read by the drawables on every draw
SkyMode skyMode = SkyMode.ibl;

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
