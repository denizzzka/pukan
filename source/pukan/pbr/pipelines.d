module pukan.pbr.pipelines;

import pukan.exceptions: PukanException;
import pukan.vulkan.pipelines: GraphicsPipelineCfg, PipelineFactory, PipelineKey;
import pukan.vulkan.renderpass: RenderPass;
import std.conv: to;
import std.meta: AliasSeq, NoDuplicates, staticMap;
import std.traits: FieldNameTuple;

/// Shader/profile set a pipeline belongs to
enum PbrProfile
{
    /// glTF PBR materials
    gltf,
    /// Godot StandardMaterial3D materials
    godot,
}

version(PbrGltfOnly)
{
    enum bool pbrGltfActive = true;
    enum bool pbrGodotActive = false;
}
else version(PbrGodotOnly)
{
    enum bool pbrGltfActive = false;
    enum bool pbrGodotActive = true;
}
else
{
    enum bool pbrGltfActive = true;
    enum bool pbrGodotActive = true;
}

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
enum bool pipelineWarmupPerScene = pipelineWarmupPolicy == PipelineWarmupPolicy.scene;
enum bool pipelineWarmupEverything = pipelineWarmupPolicy == PipelineWarmupPolicy.all;
enum bool pipelineWarmupRequired = pipelineWarmupPolicy == PipelineWarmupPolicy.required;

/// One concrete pipeline variant, independent of the profile that provides it
struct PbrVariant
{
    enum Mode { pbr, pbrCore, lit, unlit }
    enum Sky { ibl, analytic, none }
    enum State { opaque, doubleSided, blend, doubleSidedBlend, oit, doubleSidedOit }
    enum Shadow { none, normal, mask }

    bool skinned;
    Mode mode;
    Sky sky;
    State state;
    Shadow shadow = Shadow.none;
}

private template modulePipelineVariants(M)
{
    static if(__traits(hasMember, M, "pipelineVariants"))
        alias modulePipelineVariants = __traits(getMember, M, "pipelineVariants");
    else
        alias modulePipelineVariants = AliasSeq!();
}

/// Union of the variant groups declared by the given modules
template Variants(Modules...)
{
    alias Variants = NoDuplicates!(staticMap!(modulePipelineVariants, Modules));
}

/// A pipeline variant created on first use
struct LazyPipeline
{
    private GraphicsPipelineCfg cfg;
    private PipelineFactory factory;
    private PipelineKey technique;
    private RenderPass pass;
    private uint subpass;

    this(PipelineFactory factory, PipelineKey technique, RenderPass pass, uint subpass)
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

/// Pipeline variants of one shader profile, shared by every instance
final class PbrPipelines
{
    PbrModePipelines skinned;
    PbrModePipelines unskinned;
    LazyPipeline skinnedShadow;
    LazyPipeline unskinnedShadow;
    /// Alpha-tested variants for masked cutouts
    LazyPipeline skinnedMaskShadow;
    LazyPipeline unskinnedMaskShadow;

    /// Queues every variant of this profile for the preload thread
    void warmAll()
    {
        static foreach(member; FieldNameTuple!PbrPipelines)
            warmField(__traits(getMember, this, member));
    }

    /// Queues one concrete variant of this profile
    void warmVariant(in PbrVariant variant)
    {
        if(variant.shadow != PbrVariant.Shadow.none)
        {
            if(variant.shadow == PbrVariant.Shadow.normal)
            {
                if(variant.skinned)
                    skinnedShadow.request();
                else
                    unskinnedShadow.request();
            }
            else
            {
                if(variant.skinned)
                    skinnedMaskShadow.request();
                else
                    unskinnedMaskShadow.request();
            }

            return;
        }

        if(variant.skinned)
            warmMaterial(skinned, variant);
        else
            warmMaterial(unskinned, variant);
    }

    private static void warmMaterial(ref PbrModePipelines modes, in PbrVariant variant)
    {
        final switch(variant.mode)
        {
            case PbrVariant.Mode.pbr:
                final switch(variant.sky)
                {
                    case PbrVariant.Sky.ibl: requestState(modes.pbr.ibl, variant.state); break;
                    case PbrVariant.Sky.analytic: requestState(modes.pbr.analytic, variant.state); break;
                    case PbrVariant.Sky.none: requestState(modes.pbr.none, variant.state); break;
                }
                break;
            case PbrVariant.Mode.pbrCore:
                final switch(variant.sky)
                {
                    case PbrVariant.Sky.ibl: requestState(modes.pbrCore.ibl, variant.state); break;
                    case PbrVariant.Sky.analytic: requestState(modes.pbrCore.analytic, variant.state); break;
                    case PbrVariant.Sky.none: requestState(modes.pbrCore.none, variant.state); break;
                }
                break;
            case PbrVariant.Mode.lit:
                requestState(modes.lit, variant.state);
                break;
            case PbrVariant.Mode.unlit:
                requestState(modes.unlit, variant.state);
                break;
        }
    }

    private static void requestState(ref PbrPipelineVariants variants, PbrVariant.State state)
    {
        final switch(state)
        {
            case PbrVariant.State.opaque: variants.opaque.request(); break;
            case PbrVariant.State.doubleSided: variants.doubleSided.request(); break;
            case PbrVariant.State.blend: variants.blend.request(); break;
            case PbrVariant.State.doubleSidedBlend: variants.doubleSidedBlend.request(); break;
            case PbrVariant.State.oit: variants.oit.request(); break;
            case PbrVariant.State.doubleSidedOit: variants.doubleSidedOit.request(); break;
        }
    }

    /// Throws when a variant is still missing after the preload queue drains
    void validateAll()
    {
        static foreach(member; FieldNameTuple!PbrPipelines)
            validateField(__traits(getMember, this, member));
    }

    private static void warmField(T)(ref T value)
    {
        static if(is(T == LazyPipeline))
            value.request();
        else
            static foreach(member; FieldNameTuple!T)
                warmField(__traits(getMember, value, member));
    }

    private static void validateField(T)(ref T value)
    {
        static if(is(T == LazyPipeline))
            value.get();
        else
            static foreach(member; FieldNameTuple!T)
                validateField(__traits(getMember, value, member));
    }
}

unittest
{
    static struct Required
    {
        alias pipelineVariants = AliasSeq!(
            PbrVariant(skinned: true, mode: PbrVariant.Mode.lit, state: PbrVariant.State.opaque),
            PbrVariant(skinned: true, mode: PbrVariant.Mode.lit, state: PbrVariant.State.opaque),
            PbrVariant(skinned: false, mode: PbrVariant.Mode.pbr, sky: PbrVariant.Sky.ibl, state: PbrVariant.State.opaque),
        );
    }

    static assert(Variants!Required.length == 2);
}
