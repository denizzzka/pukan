module pukan.godot_scene.scene;

import dlib.math: Matrix4x4f, Vector3f, Vector4f;
import pukan.gltf: GlTF;
import pukan.godot_scene.environment: GodotEnvironment;
import pukan.graphics.common.misc: Boxf, hasBounds, isVisible, mergeAabb, transformAabb;
import pukan.graphics.g3d.cell_index: Bounded;
import pukan.graphics.g3d.material: AlphaMode, Material, MaterialBuffer, MaterialMode;
import pukan.graphics.g3d.mesh: mirrors;
import pukan.graphics.g3d.pbr.accessor: BufferPieceOnGPU;
import pukan.graphics.g3d.pbr.mesh: PbrMesh;
import pukan.graphics.g3d.pbr.pipelines: LazyPipeline, LightingMode, PbrPipelineVariants, PbrPipelines, lightingMode, oitPass, plainShading, transmissionPass;
import pukan.physics.shapes: Collider, CollisionShape;
import pukan.physics.world: CollisionWorld;
import pukan.vulkan.bindings;
import pukan.vulkan.commands: CommandPool;
import pukan.vulkan.logical_device: LogicalDevice;
import pukan.vulkan.memory: TransferBuffer;
import pukan.vulkan.pipelines: GraphicsPipelineCfg;
import pukan.vulkan.renderpass: Blended, DrawableByVulkan, DrawPhase, PipelineWarmup;
import pukan.vulkan.textures: Texture;
import std.algorithm: sort;

enum GodotLightKind
{
    directional,
    point,
    spot,
}

struct GodotBone
{
    string name;
    int parent = -1;
    Matrix4x4f rest = Matrix4x4f.identity();
    Matrix4x4f local = Matrix4x4f.identity();
    bool enabled = true;
}

/// Bone hierarchy of one Skeleton3D node
struct GodotSkeleton
{
    GodotBone[] bones;
    Matrix4x4f[] globalPoses;
}

/// One Skin resource resolved for a mesh instance
final class GodotSkin
{
    TransferBuffer buffer;
    VkDescriptorBufferInfo info;
    Matrix4x4f[] matrices;
}

struct GodotLight
{
    GodotLightKind kind;
    Vector3f position;
    Vector3f direction; // toward the light for directional, beam for spot
    Vector3f color;
    float energy = 1.0f;
    float range = 5.0f;
    float innerAngle;
    float outerAngle;
}

struct GodotCamera
{
    /// Inverse of the camera node's world transform
    Matrix4x4f view = Matrix4x4f.identity;
    float fov = 75.0f;
    float nearPlane = 0.05f;
    float farPlane = 1000.0f;
}

/// One collision shape attached to a body node
struct GodotCollider
{
    CollisionShape shape;
    Matrix4x4f local = Matrix4x4f.identity;
    uint layer = 1;
    uint mask = 1;
}

class GodotNode
{
    string name;
    string type;
    Matrix4x4f local = Matrix4x4f.identity();
    bool visible = true;
    PbrMesh[] meshes;
    GodotNode[] children;
    GodotCollider[] colliders;
    uint collisionLayer = 1;
    uint collisionMask = 1;
    bool collisionBody;

    GodotLight light;
    bool hasLight;
    GodotCamera camera;
    bool hasCamera;
    DrawableByVulkan instance;
    GodotSkeleton skeleton;
    bool hasSkeleton;
    GodotSkin skin;

    void addChild(GodotNode child)
    {
        children ~= child;
    }
}

/// One loaded Godot scene tree and its GPU resources
final class GodotScene : DrawableByVulkan, Blended, Bounded, PipelineWarmup
{
    private PbrPipelines pipelines;
    private LogicalDevice device;
    private MaterialBuffer materialBuffer;
    private GodotNode root;
    private PbrMesh[] meshes;
    private BufferPieceOnGPU[] gpuBuffs;
    private Texture[] textures;
    private VkSampler[] samplers;
    private bool uploaded;

    string name;
    size_t skippedNodes;
    size_t skippedResources;
    /// Unsupported node types, by name
    size_t[string] skippedNodeTypes;
    /// Resources referenced by those nodes, by type
    size_t[string] skippedResourceTypes;
    /// Distinct GPU geometries shared by the meshes
    size_t geometryCount;

    GodotLight[] lights;
    GodotCamera camera;
    bool hasCamera;
    GodotEnvironment environment;
    private DrawableByVulkan[] instances;
    private GodotSkin[] skins;

    package(pukan) this(
        PbrPipelines pipelines,
        LogicalDevice device,
        MaterialBuffer materialBuffer,
        GodotNode root,
        PbrMesh[] meshes,
        BufferPieceOnGPU[] gpuBuffs,
        Texture[] textures,
        VkSampler[] samplers,
        DrawableByVulkan[] instances,
        GodotSkin[] skins,
        GodotEnvironment environment,
        string name,
    )
    {
        this.pipelines = pipelines;
        this.device = device;
        this.materialBuffer = materialBuffer;
        this.root = root;
        this.meshes = meshes;
        this.gpuBuffs = gpuBuffs;
        this.textures = textures;
        this.samplers = samplers;
        this.instances = instances;
        this.skins = skins;
        this.environment = environment;
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

        foreach(sampler; samplers)
            if(sampler)
                vkDestroySampler(device.device, sampler, device.alloc);

        foreach(instance; instances)
            destroyInstance(instance);

        foreach(skin; skins)
            if(skin && skin.buffer)
                destroy(skin.buffer);
    }

    string possibleName() const => name;
    size_t meshCount() const => meshes.length;

    /// Replaces every surface material at runtime
    void setMaterialOverride(Material material)
    {
        foreach(mesh; meshes)
        {
            mesh.material = material;
            mesh.commitMaterial();
            mesh.updateDescriptorSetsAndUniformBuffers(device);
        }

        foreach(instance; instances)
            if(auto scene = cast(GodotScene) instance)
                scene.setMaterialOverride(material);
    }
    size_t instanceCount() const => instances.length;

    Boxf[] instanceBounds()
    {
        Boxf[] result;

        foreach(instance; instances)
        {
            if(auto gltf = cast(GlTF) instance)
                result ~= gltf.calcAABB;
            else if(auto scene = cast(GodotScene) instance)
                result ~= scene.calcAABB;
        }

        return result;
    }

    bool isBlended() const
    {
        if(plainShading)
            return false;

        foreach(mesh; meshes)
            if(mesh.alphaMode == AlphaMode.blend)
                return true;

        foreach(instance; instances)
            if(auto blended = cast(Blended) instance)
                if(blended.isBlended())
                    return true;

        return false;
    }

    Boxf calcAABB()
    {
        bool complete;
        return calcAABB(complete);
    }

    /// Bounds of everything the scene draws; NaN when a part cannot bound itself
    Boxf localBounds()
    {
        bool complete;
        const box = calcAABB(complete);

        return complete ? box : Boxf.init;
    }

    /// Bounds of the visible parts; `complete` reports whether each one could bound itself
    private Boxf calcAABB(ref bool complete)
    {
        Boxf result;

        void collect(Matrix4x4f trans, GodotNode node)
        {
            if(!node.visible)
                return;

            trans *= node.local;

            foreach(mesh; node.meshes)
                if(hasBounds(mesh.localAABB))
                    mergeAabb(result, transformAabb(mesh.localAABB, trans));
                else
                    complete = false;

            if(node.instance !is null)
            {
                auto bounded = cast(Bounded) node.instance;

                if(bounded is null)
                    complete = false;
                else
                {
                    const box = bounded.localBounds;

                    if(hasBounds(box))
                        mergeAabb(result, transformAabb(box, trans));
                    else
                        complete = false;
                }
            }

            foreach(child; node.children)
                collect(trans, child);
        }

        collect(Matrix4x4f.identity, root);

        return result;
    }

    /// First Marker3D or CharacterBody3D origin, used as a character spawn
    bool spawnPosition(out Vector3f position)
    {
        return findSpawn(root, Matrix4x4f.identity, position);
    }

    private static bool findSpawn(GodotNode node, Matrix4x4f trans, out Vector3f position)
    {
        trans *= node.local;

        if(node.type == "Marker3D" || node.type == "CharacterBody3D")
        {
            position = Vector3f(trans.a14, trans.a24, trans.a34);
            return true;
        }

        if(auto scene = cast(GodotScene) node.instance)
            if(scene.findSpawn(scene.root, trans, position))
                return true;

        foreach(child; node.children)
            if(findSpawn(child, trans, position))
                return true;

        return false;
    }

    /// Adds every collision shape in the tree to `world` and builds it
    void buildCollisionWorld(CollisionWorld world)
    {
        collectColliders(root, Matrix4x4f.identity, world);
        world.build();
    }

    private void collectColliders(GodotNode node, Matrix4x4f trans, CollisionWorld world)
    {
        trans *= node.local;

        foreach(collider; node.colliders)
            world.add(Collider(collider.shape, trans * collider.local, collider.layer, collider.mask));

        if(auto scene = cast(GodotScene) node.instance)
            scene.collectColliders(scene.root, trans, world);

        foreach(child; node.children)
            collectColliders(child, trans, world);
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

            foreach(skin; skins)
                skin.buffer.recordUpload(buf);

            materialBuffer.recordUpload(buf);
        });

        foreach(instance; instances)
            instance.uploadToGPUImmediate(device, commandPool, commandBuffer);

        foreach(mesh; meshes)
            mesh.updateDescriptorSetsAndUniformBuffers(device);

        uploaded = true;
    }

    void refreshBuffers(VkCommandBuffer buf)
    {
        foreach(instance; instances)
            instance.refreshBuffers(buf);
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

        void collect(Matrix4x4f trans, GodotNode node, ref MeshDraw[] draws, bool mirrored)
        {
            if(!node.visible)
                return;

            trans *= node.local;

            debug
            {
                mirrored = mirrored != node.local.mirrors;

                foreach(mesh; node.meshes)
                    assert(mesh.mirrored == mirrored, "mesh winding does not match its transform");
            }

            foreach(mesh; node.meshes)
            {
                //TODO: cull skinned meshes by their posed bounds
                if(!mesh.hasSkin && !isVisible(mesh.localAABB, trans))
                    continue;

                const clip = Vector4f(0, 0, 0, 1) * trans;
                draws ~= MeshDraw(mesh, trans, clip.w);
            }

            foreach(child; node.children)
                collect(trans, child, draws, mirrored);
        }

        MeshDraw[] draws;
        collect(trans, root, draws, false);

        if(phase == DrawPhase.blended)
            draws.sort!((a, b) => a.depth > b.depth);

        if(phase == DrawPhase.surface || phase == DrawPhase.shadow)
        {
            PbrMesh[] order;
            Matrix4x4f[][PbrMesh] groups;

            foreach(draw; draws)
            {
                if(!matchesPhase(draw.mesh, phase))
                    continue;

                //TODO: batch skinned meshes that share a pose
                if(draw.mesh.hasSkin)
                {
                    draw.mesh.draw(buf, selectPipeline(draw.mesh, phase), draw.trans, frameSet);
                    continue;
                }

                if(auto group = draw.mesh in groups)
                    *group ~= draw.trans;
                else
                {
                    order ~= draw.mesh;
                    groups[draw.mesh] = [draw.trans];
                }
            }

            foreach(mesh; order)
                mesh.drawBatch(buf, selectPipeline(mesh, phase), groups[mesh], frameSet);
        }
        else
            foreach(draw; draws)
                if(matchesPhase(draw.mesh, phase))
                    draw.mesh.draw(buf, selectPipeline(draw.mesh, phase), draw.trans, frameSet);

        void drawInstances(GodotNode node, Matrix4x4f trans)
        {
            if(!node.visible)
                return;

            trans *= node.local;

            if(node.instance !is null)
            {
                debug
                {
                    import std.stdio: writeln;
                    static bool printed;
                    if(!printed)
                    {
                        printed = true;
                        writeln("GodotScene instance draw ", node.name, " phase ", phase);
                    }
                }

                node.instance.drawingBufferFilling(buf, trans, frameSet, phase);
            }

            foreach(child; node.children)
                drawInstances(child, trans);
        }

        drawInstances(root, trans);
    }

    private static void destroyInstance(DrawableByVulkan instance)
    {
        if(auto gltf = cast(GlTF) instance)
            destroy(gltf);
        else if(auto scene = cast(GodotScene) instance)
            destroy(scene);
    }

    private static bool matchesPhase(const PbrMesh mesh, DrawPhase phase)
    {
        const blended = !plainShading && mesh.alphaMode == AlphaMode.blend;
        const transmissive = !plainShading && mesh.material.transmission.x > 0.0f;
        const ownPass = transmissive && transmissionPass;

        if(phase == DrawPhase.shadow)
            return mesh.castShadow && !blended && !transmissive &&
                (mesh.alphaMode == AlphaMode.opaque || mesh.alphaMode == AlphaMode.mask);

        if(mesh.shadowsOnly)
            return false;

        if(phase == DrawPhase.transmission)
            return transmissive;

        if(phase == DrawPhase.blended)
            return blended && !ownPass;

        return !blended && !ownPass;
    }

    private LazyPipeline* selectPipelineSlot(
        const PbrMesh mesh,
        DrawPhase phase,
        LightingMode mode = lightingMode,
        bool oit = oitPass,
    )
    {
        if(phase == DrawPhase.shadow)
            return mesh.alphaMode == AlphaMode.mask
                ? (mesh.hasSkin ? &pipelines.skinnedMaskShadow : &pipelines.unskinnedMaskShadow)
                : (mesh.hasSkin ? &pipelines.skinnedShadow : &pipelines.unskinnedShadow);

        auto modes = mesh.hasSkin ? &pipelines.skinned : &pipelines.unskinned;

        if(plainShading)
            return mesh.doubleSided ? &modes.lit.doubleSided : &modes.lit.opaque;

        if(mesh.material.mode == MaterialMode.unlit || mode == LightingMode.unlit)
            return selectVariantSlot(modes.unlit, mesh, oit);

        if(mesh.material.mode == MaterialMode.lit)
            return selectVariantSlot(modes.lit, mesh, oit);

        auto pbr = mesh.material.needsExtendedShading ? &modes.pbr : &modes.pbrCore;

        auto variants = mode == LightingMode.analytic ? &pbr.analytic
            : mode == LightingMode.none ? &pbr.none
            : &pbr.ibl;

        return selectVariantSlot(*variants, mesh, oit);
    }

    private static LazyPipeline* selectVariantSlot(ref PbrPipelineVariants variants, const PbrMesh mesh, bool oit)
    {
        if(mesh.alphaMode == AlphaMode.blend)
        {
            if(oit)
                return mesh.doubleSided ? &variants.doubleSidedOit : &variants.oit;

            return mesh.doubleSided ? &variants.doubleSidedBlend : &variants.blend;
        }

        return mesh.doubleSided ? &variants.doubleSided : &variants.opaque;
    }

    private GraphicsPipelineCfg selectPipeline(const PbrMesh mesh, DrawPhase phase)
    {
        return selectPipelineSlot(mesh, phase).get(mesh.name);
    }

    void warmPipelines(bool shadows)
    {
        foreach(mesh; meshes)
        {
            foreach(mode; [LightingMode.ibl, LightingMode.analytic, LightingMode.none, LightingMode.unlit])
                foreach(oit; [true, false])
                {
                    if(matchesPhase(mesh, DrawPhase.surface))
                        selectPipelineSlot(mesh, DrawPhase.surface, mode, oit).request();

                    if(matchesPhase(mesh, DrawPhase.transmission))
                        selectPipelineSlot(mesh, DrawPhase.transmission, mode, oit).request();

                    if(matchesPhase(mesh, DrawPhase.blended))
                        selectPipelineSlot(mesh, DrawPhase.blended, mode, oit).request();
                }

            if(shadows && matchesPhase(mesh, DrawPhase.shadow))
                selectPipelineSlot(mesh, DrawPhase.shadow).request();
        }

        foreach(instance; instances)
            if(auto warm = cast(PipelineWarmup) instance)
                warm.warmPipelines(shadows);
    }
}
