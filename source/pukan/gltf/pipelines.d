module pukan.gltf.pipelines;

import pukan.vulkan.pipelines: GraphicsPipelineCfg;

struct GltfPipelineVariants
{
    GraphicsPipelineCfg opaque;
    GraphicsPipelineCfg doubleSided;
    GraphicsPipelineCfg blend;
    GraphicsPipelineCfg doubleSidedBlend;
}

/// One shader per material mode; the mode is fixed when the file is loaded
struct GltfModePipelines
{
    GltfPipelineVariants pbr;
    GltfPipelineVariants lit;
    GltfPipelineVariants unlit;
}

struct GltfPipelines
{
    GltfModePipelines skinned;
    GltfModePipelines unskinned;
}
