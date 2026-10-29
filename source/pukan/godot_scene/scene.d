module pukan.godot_scene.scene;

import dlib.math: Matrix4x4f, Vector4f;
import pukan.material: AlphaMode, MaterialBuffer, MaterialMode;
import pukan.misc: Boxf;
import pukan.pbr.accessor: BufferPieceOnGPU;
import pukan.pbr.mesh: PbrMesh;
import pukan.pbr.pipelines: LightingMode, PbrPipelineVariants, PbrPipelines, lightingMode, oitPass, transmissionPass;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.renderpass: Blended, DrawableByVulkan, DrawPhase;
import pukan.vulkan.textures: Texture;
import std.algorithm: sort;

class GodotNode
{
    string name;
    size_t skippedNodes;
    size_t skippedResources;
    Matrix4x4f local = Matrix4x4f.identity();
    bool visible = true;
    PbrMesh[] meshes;
    GodotNode[] children;

    void addChild(GodotNode child)
    {
        children ~= child;
    }
}

/// One loaded Godot scene tree and its GPU resources
final class GodotScene : DrawableByVulkan, Blended
{
    private PbrPipelines pipelines;
    private MaterialBuffer materialBuffer;
    private GodotNode root;
    private PbrMesh[] meshes;
    private BufferPieceOnGPU[] gpuBuffs;
    private Texture[] textures;
    private bool uploaded;

    string name;
    size_t skippedNodes;
    size_t skippedResources;

    package(pukan) this(
        ref PbrPipelines pipelines,
        MaterialBuffer materialBuffer,
        GodotNode root,
        PbrMesh[] meshes,
        BufferPieceOnGPU[] gpuBuffs,
        Texture[] textures,
        string name,
    )
    {
        this.pipelines = pipelines;
        this.materialBuffer = materialBuffer;
        this.root = root;
        this.meshes = meshes;
        this.gpuBuffs = gpuBuffs;
        this.textures = textures;
        this.name = name;
    }

    ~this()
    {
        foreach(ref piece; gpuBuffs)
            if(piece && piece.buffer)
                destroy(piece.buffer);

        foreach(ref texture; textures)
            if(texture)
                destroy(texture);
    }

    string possibleName() const => name;
    size_t meshCount() const => meshes.length;

    bool isBlended() const
    {
        foreach(mesh; meshes)
            if(mesh.alphaMode == AlphaMode.blend)
                return true;

        return false;
    }

    Boxf calcAABB() const
    {
        Boxf result;

        foreach(mesh; meshes)
            mesh.calcAABB(gpuBuffs, result);

        return result;
    }

    void uploadToGPUImmediate(
        LogicalDevice device,
        CommandPool commandPool,
        scope VkCommandBuffer commandBuffer,
    )
    {
        if(uploaded)
            return;

        commandPool.recordOneTimeAndSubmit(commandBuffer, (buf) {
            foreach(ref piece; gpuBuffs)
                if(piece)
                    piece.recordUpload(buf);

            materialBuffer.recordUpload(buf);
        });

        foreach(mesh; meshes)
            mesh.updateDescriptorSetsAndUniformBuffers(device);

        uploaded = true;
    }

    void refreshBuffers(VkCommandBuffer buf)
    {
    }

    void drawingBufferFilling(
        VkCommandBuffer buf,
        Matrix4x4f trans,
        VkDescriptorSet frameSet,
        DrawPhase phase = DrawPhase.surface,
    )
    {
        static struct MeshDraw
        {
            PbrMesh mesh;
            Matrix4x4f trans;
            float depth;
        }

        void collect(Matrix4x4f trans, GodotNode node, ref MeshDraw[] draws)
        {
            if(!node.visible)
                return;

            trans *= node.local;

            foreach(mesh; node.meshes)
            {
                const clip = Vector4f(0, 0, 0, 1) * trans;
                draws ~= MeshDraw(mesh, trans, clip.w);

            }

            foreach(child; node.children)
                collect(trans, child, draws);
        }

        MeshDraw[] draws;
        collect(trans, root, draws);

        if(phase == DrawPhase.blended)
            draws.sort!((a, b) => a.depth > b.depth);

        foreach(draw; draws)
            if(matchesPhase(draw.mesh, phase))
                draw.mesh.draw(buf, selectPipeline(draw.mesh, phase), draw.trans, frameSet);
    }

    private static bool matchesPhase(const PbrMesh mesh, DrawPhase phase)
    {
        const blended = mesh.alphaMode == AlphaMode.blend;
        const transmissive = mesh.material.transmission.x > 0.0f;
        const ownPass = transmissive && transmissionPass;

        if(phase == DrawPhase.transmission)
            return transmissive;

        if(phase == DrawPhase.blended)
            return blended && !ownPass;

        if(phase == DrawPhase.shadow)
            return !blended && !transmissive && mesh.alphaMode == AlphaMode.opaque;

        return !blended && !ownPass;
    }

    private GraphicsPipelineCfg selectPipeline(const PbrMesh mesh, DrawPhase phase)
    {
        if(phase == DrawPhase.shadow)
            return mesh.hasSkin ? pipelines.skinnedShadow : pipelines.unskinnedShadow;

        auto modes = mesh.hasSkin ? pipelines.skinned : pipelines.unskinned;

        if(mesh.material.mode == MaterialMode.unlit || lightingMode == LightingMode.unlit)
            return selectVariant(modes.unlit, mesh);

        if(mesh.material.mode == MaterialMode.lit)
            return selectVariant(modes.lit, mesh);

        auto pbr = mesh.material.needsExtendedShading ? modes.pbr : modes.pbrCore;

        auto variants = lightingMode == LightingMode.analytic ? pbr.analytic
            : lightingMode == LightingMode.none ? pbr.none
            : pbr.ibl;

        return selectVariant(variants, mesh);
    }

    private static GraphicsPipelineCfg selectVariant(PbrPipelineVariants variants, const PbrMesh mesh)
    {
        if(mesh.alphaMode == AlphaMode.blend)
        {
            if(oitPass)
                return mesh.doubleSided ? variants.doubleSidedOit : variants.oit;

            return mesh.doubleSided ? variants.doubleSidedBlend : variants.blend;
        }

        return mesh.doubleSided ? variants.doubleSided : variants.opaque;
    }
}
