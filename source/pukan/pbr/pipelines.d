module pukan.pbr.pipelines;

import pukan.exceptions: PukanException;
import pukan.vulkan.pipelines: GraphicsPipelineCfg, PipelineFactory, TechniqueId;
import pukan.vulkan.renderpass: RenderPass;
import std.conv: to;

/// When pipeline variants are built
enum PipelineWarmupPolicy
{
    /// Build each variant on its first draw; no worker or query
    off,
    /// Queue the variants of each loaded object; late ones build on demand
    scene,
    /// Queue every reachable variant for the target at scene setup
    all,
    /// Queue only the required set; a variant outside it is an error
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
enum bool pipelineWarmupEverything = pipelineWarmupPolicy == PipelineWarmupPolicy.all;

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

    GraphicsPipelineCfg get(string context = null)
    {
        if(cfg.graphicsPipeline is null)
        {
            static if(pipelineWarmupPolicy == PipelineWarmupPolicy.off ||
                      pipelineWarmupPolicy == PipelineWarmupPolicy.scene)
                cfg = factory.acquire(technique, pass, subpass);
            else
            {
                GraphicsPipelineCfg ready;
                if(factory.tryAcquire(technique, pass, subpass, ready))
                    cfg = ready;
                else
                {
                    string message = "pipeline variant was not preloaded: " ~
                        factory.techniqueName(technique) ~
                        " for " ~ pass.imageFormat.to!string ~
                        ", subpass " ~ subpass.to!string;

                    if(context.length)
                        message ~= ", " ~ context;

                    throw new PukanException(message);
                }
            }
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

    /// Queues every variant of this family for the preload thread
    void warmAll()
    {
        warmAll(skinned);
        warmAll(unskinned);

        skinnedShadow.request();
        unskinnedShadow.request();
        skinnedMaskShadow.request();
        unskinnedMaskShadow.request();
    }

    /// Throws when a variant is still missing after the preload queue drains
    void validateAll()
    {
        validateAll(skinned);
        validateAll(unskinned);

        skinnedShadow.get();
        unskinnedShadow.get();
        skinnedMaskShadow.get();
        unskinnedMaskShadow.get();
    }

    private static void warmAll(ref PbrModePipelines modes)
    {
        warmAll(modes.pbr);
        warmAll(modes.pbrCore);
        warmAll(modes.lit);
        warmAll(modes.unlit);
    }

    private static void warmAll(ref PbrSkyPipelines skies)
    {
        warmAll(skies.ibl);
        warmAll(skies.analytic);
        warmAll(skies.none);
    }

    private static void warmAll(ref PbrPipelineVariants variants)
    {
        variants.opaque.request();
        variants.doubleSided.request();
        variants.blend.request();
        variants.doubleSidedBlend.request();
        variants.oit.request();
        variants.doubleSidedOit.request();
    }

    private static void validateAll(ref PbrModePipelines modes)
    {
        validateAll(modes.pbr);
        validateAll(modes.pbrCore);
        validateAll(modes.lit);
        validateAll(modes.unlit);
    }

    private static void validateAll(ref PbrSkyPipelines skies)
    {
        validateAll(skies.ibl);
        validateAll(skies.analytic);
        validateAll(skies.none);
    }

    private static void validateAll(ref PbrPipelineVariants variants)
    {
        variants.opaque.get();
        variants.doubleSided.get();
        variants.blend.get();
        variants.doubleSidedBlend.get();
        variants.oit.get();
        variants.doubleSidedOit.get();
    }
}
