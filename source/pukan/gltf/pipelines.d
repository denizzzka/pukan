module pukan.gltf.pipelines;

import pukan.vulkan.pipelines: GraphicsPipelineCfg;

struct GltfPipelines
{
    GraphicsPipelineCfg opaque;
    GraphicsPipelineCfg doubleSided;
    GraphicsPipelineCfg blend;
    GraphicsPipelineCfg doubleSidedBlend;
}
