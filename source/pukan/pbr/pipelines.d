module pukan.pbr.pipelines;

import pukan.exceptions: PukanException;
import pukan.vulkan.pipelines: GraphicsPipelineCfg, PipelineFactory, TechniqueId;
import pukan.vulkan.renderpass: RenderPass;
import std.conv: to;

/// When pipeline variants are built
enum PipelineWarmupPolicy
{
    off,
    scene,
    all,
    required,
}

version(PipelineWarmupOff)
    enum pipelineWarmupPolicy = PipelineWarmupPolicy.off;
else version(PipelineWarmupAll)
    enum pipelineWarmupPolicy = PipelineWarmupPolicy.all;
else version(PipelineWarmupRequired)
    enum pipelineWarmupPolicy = PipelineWarmupPolicy.required;
else
    enum pipelineWarmupPolicy = PipelineWarmupPolicy.scene;

enum bool pipelineWarmupEnabled = pipelineWarmupPolicy != PipelineWarmupPolicy.off;
enum bool pipelineWarmupPerScene = pipelineWarmupPolicy == PipelineWarmupPolicy.scene ||
    pipelineWarmupPolicy == PipelineWarmupPolicy.required;

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
        {
            static if(pipelineWarmupPolicy == PipelineWarmupPolicy.off ||
                      pipelineWarmupPolicy == PipelineWarmupPolicy.scene)
                cfg = factory.acquire(technique, pass, subpass);
            else
                throw new PukanException(
                    "pipeline variant was not preloaded: " ~
                    factory.techniqueName(technique) ~
                    " for " ~ pass.imageFormat.to!string ~
                    ", subpass " ~ subpass.to!string);
        }

        return cfg;
    }

    bool ready() const => cfg.graphicsPipeline !is null;

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
