module pukan.pbr.pipelines;

import pukan.vulkan.pipelines: GraphicsPipelineCfg, PipelineFactory, TechniqueId;
import pukan.vulkan.renderpass: RenderPass;

/// A pipeline variant created on first use
struct LazyPipeline
{
    private GraphicsPipelineCfg cfg;
    private PipelineFactory factory;
    private TechniqueId technique;
    private RenderPass pass;
    private uint subpass;

    this(PipelineFactory factory, TechniqueId technique, RenderPass pass, uint subpass)
    {
        this.factory = factory;
        this.technique = technique;
        this.pass = pass;
        this.subpass = subpass;
    }

    GraphicsPipelineCfg get()
    {
        if(cfg.graphicsPipeline is null)
            cfg = factory.acquire(technique, pass, subpass);

        return cfg;
    }

    void request()
    {
        factory.request(technique, pass, subpass);
    }

    alias get this;
}

struct PbrPipelineVariants
{
    LazyPipeline opaque;
    LazyPipeline doubleSided;
    LazyPipeline blend;
    LazyPipeline doubleSidedBlend;
    LazyPipeline oit;
    LazyPipeline doubleSidedOit;
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

/// Pipeline variants of the glTF and Godot families, shared by every instance
final class PbrPipelines
{
    PbrModePipelines skinned;
    PbrModePipelines unskinned;
    LazyPipeline skinnedShadow;
    LazyPipeline unskinnedShadow;
    /// Alpha-tested variants for masked cutouts
    LazyPipeline skinnedMaskShadow;
    LazyPipeline unskinnedMaskShadow;
}
