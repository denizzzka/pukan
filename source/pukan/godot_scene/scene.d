module pukan.godot_scene.scene;

import dlib.math: Matrix4x4f, Vector3f, Vector4f;
import pukan.gltf: GlTF;
import pukan.godot_scene.environment: GodotEnvironment;
import pukan.graphics.common.misc: Boxf, hasBounds, isVisible, mergePartAabb;
import pukan.graphics.g3d.cell_index: Bounded, Part, PartDrawable, wholePart;
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
import pukan.vulkan.pipelines: DescriptorAllocator, GraphicsPipelineCfg;
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
final class GodotScene : DrawableByVulkan, Blended, Bounded, PartDrawable, PipelineWarmup
{
    private PbrPipelines pipelines;
    private LogicalDevice device;
    /// Owns the material descriptor sets of this scene's meshes
    private DescriptorAllocator allocator;
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

    /// Leaf parts, registered once so a frame walks no nodes
    private PartRecord[] parts;
    private size_t[] allKeys;
    private bool partsRegistered;

    /// Holders per mesh and per GPU piece, so a released cell frees what nothing holds
    private size_t[PbrMesh] meshRefs;
    private size_t[] pieceRefs;
    /// Meshes whose GPU handles are resolved and whose pieces are uploaded
    private bool[PbrMesh] meshReady;

    private struct PartRecord
    {
        PbrMesh mesh;
        DrawableByVulkan nested;
        size_t nestedKey;
        /// Part transform inside this scene
        Matrix4x4f world;
        /// Transform of the nested drawable itself
        Matrix4x4f base;
        Boxf bounds;
    }

    package(pukan) this(
        PbrPipelines pipelines,
        LogicalDevice device,
        DescriptorAllocator allocator,
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
        this.allocator = allocator;
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
        // The descriptor sets sample the textures and buffers below, so free them first
        if(allocator)
            destroy(allocator);

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

    /// Bounds of the parts that report extents; used for shadows and spawn
    Boxf calcAABB() => collectBounds(false);

    Boxf localBounds() => calcAABB;

    /// Bounds for cell placement: a part without bounds still contributes its origin
    Boxf cellBounds() => collectBounds(true);

    private Boxf collectBounds(bool byOrigin)
    {
        registerParts();

        Boxf result;

        foreach(record; parts)
            mergePartAabb(result, record.bounds, record.world, byOrigin);

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
            foreach(skin; skins)
                skin.buffer.recordUpload(buf);

            materialBuffer.recordUpload(buf);
        });

        foreach(instance; instances)
            instance.uploadToGPUImmediate(device, commandPool, commandBuffer);

        foreach(mesh; meshes)
            mesh.updateDescriptorSetsAndUniformBuffers(device);

        registerParts();

        // A part no cell can hold stays loaded, since no cell will ever release it
        foreach(record; parts)
            if(record.mesh !is null && !hasBounds(record.bounds))
                ++meshRefs[record.mesh];

        uploaded = true;
    }

    void refreshBuffers(VkCommandBuffer buf)
    {
        foreach(instance; instances)
            instance.refreshBuffers(buf);
    }

    /// Registers every part once; a frame draws from this list instead of the nodes
    private void registerParts()
    {
        if(partsRegistered)
            return;

        void collect(Matrix4x4f trans, GodotNode node, bool mirrored)
        {
            if(!node.visible)
                return;

            trans *= node.local;

            debug mirrored = mirrored != node.local.mirrors;

            foreach(mesh; node.meshes)
            {
                debug assert(mesh.mirrored == mirrored, "mesh winding does not match its transform");

                parts ~= PartRecord(mesh, null, wholePart, trans, trans, mesh.localAABB);
            }

            if(node.instance !is null)
            {
                if(auto perPart = cast(PartDrawable) node.instance)
                    perPart.eachPart((in Part part) {
                        parts ~= PartRecord(
                            nested: node.instance,
                            nestedKey: part.key,
                            world: trans * part.local,
                            base: trans,
                            bounds: part.bounds,
                        );
                    });
                else
                {
                    auto bounded = cast(Bounded) node.instance;

                    parts ~= PartRecord(
                        nested: node.instance,
                        nestedKey: wholePart,
                        world: trans,
                        base: trans,
                        bounds: bounded is null ? Boxf.init : bounded.localBounds,
                    );
                }
            }

            foreach(child; node.children)
                collect(trans, child, mirrored);
        }

        collect(Matrix4x4f.identity, root, false);

        pieceRefs.length = gpuBuffs.length;

        allKeys.length = parts.length;
        foreach(i; 0 .. parts.length)
            allKeys[i] = i;

        partsRegistered = true;
    }

    void drawingBufferFilling(
        VkCommandBuffer buf,
        Matrix4x4f trans,
        VkDescriptorSet frameSet,
        DrawPhase phase = DrawPhase.surface,
    )
    {
        drawParts(buf, trans, allKeys, frameSet, phase);
    }

    void drawParts(
        VkCommandBuffer buf,
        in Matrix4x4f trans,
        scope const(size_t)[] keys,
        VkDescriptorSet frameSet,
        DrawPhase phase,
    )
    {
        registerParts();

        static struct MeshDraw
        {
            PbrMesh mesh;
            Matrix4x4f trans;
            float depth;
        }

        static struct NestedGroup
        {
            DrawableByVulkan drawable;
            Matrix4x4f base;
            size_t[] keys;
        }

        MeshDraw[] draws;
        NestedGroup[] groups;

        foreach(key; keys)
        {
            auto record = &parts[key];

            if(record.mesh is null)
            {
                size_t found = groups.length;

                foreach(g, group; groups)
                    if(group.drawable is record.nested && group.base == record.base)
                    {
                        found = g;
                        break;
                    }

                if(found == groups.length)
                    groups ~= NestedGroup(record.nested, record.base);

                groups[found].keys ~= record.nestedKey;

                continue;
            }

            // A part whose pieces are not on the GPU yet has no buffer to bind
            if(!meshReady.get(record.mesh, false))
                continue;

            const mvp = trans * record.world;

            //TODO: cull skinned meshes by their posed bounds
            if(!record.mesh.hasSkin && !isVisible(record.mesh.localAABB, mvp))
                continue;

            const clip = Vector4f(0, 0, 0, 1) * mvp;
            draws ~= MeshDraw(record.mesh, mvp, clip.w);
        }

        if(phase == DrawPhase.blended)
            draws.sort!((a, b) => a.depth > b.depth);

        if(phase == DrawPhase.surface || phase == DrawPhase.shadow)
        {
            PbrMesh[] order;
            Matrix4x4f[][PbrMesh] batches;

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

                if(auto batch = draw.mesh in batches)
                    *batch ~= draw.trans;
                else
                {
                    order ~= draw.mesh;
                    batches[draw.mesh] = [draw.trans];
                }
            }

            foreach(mesh; order)
                mesh.drawBatch(buf, selectPipeline(mesh, phase), batches[mesh], frameSet);
        }
        else
            foreach(draw; draws)
                if(matchesPhase(draw.mesh, phase))
                    draw.mesh.draw(buf, selectPipeline(draw.mesh, phase), draw.trans, frameSet);

        foreach(group; groups)
            if(auto perPart = cast(PartDrawable) group.drawable)
                perPart.drawParts(buf, trans * group.base, group.keys, frameSet, phase);
            else
                group.drawable.drawingBufferFilling(buf, trans * group.base, frameSet, phase);
    }

    void holdParts(scope const(size_t)[] keys)
    {
        registerParts();

        static struct NestedGroup
        {
            DrawableByVulkan drawable;
            size_t[] keys;
        }

        NestedGroup[] groups;

        foreach(key; keys)
        {
            auto record = &parts[key];

            if(record.mesh !is null)
            {
                ++meshRefs[record.mesh];
                continue;
            }

            size_t found = groups.length;

            foreach(g, group; groups)
                if(group.drawable is record.nested)
                {
                    found = g;
                    break;
                }

            if(found == groups.length)
                groups ~= NestedGroup(record.nested);

            groups[found].keys ~= record.nestedKey;
        }

        foreach(group; groups)
            if(auto perPart = cast(PartDrawable) group.drawable)
                perPart.holdParts(group.keys);
    }

    size_t uploadParts(VkCommandBuffer buf, size_t budget)
    {
        registerParts();

        size_t used;

        foreach(record; parts)
        {
            if(record.mesh is null || meshReady.get(record.mesh, false))
                continue;

            if(meshRefs.get(record.mesh, 0) == 0)
                continue;

            size_t need;

            foreach(piece; record.mesh.pieces)
                if(!gpuBuffs[piece].isUploaded)
                    need += gpuBuffs[piece].buffer.length;

            // A mesh larger than the whole budget still uploads alone, so nothing stalls
            if(used > 0 && used + need > budget)
                continue;

            foreach(piece; record.mesh.pieces)
                if(pieceRefs[piece]++ == 0 && !gpuBuffs[piece].isUploaded)
                    gpuBuffs[piece].recordUpload(buf);

            record.mesh.buildGeometry(gpuBuffs);
            meshReady[record.mesh] = true;
            used += need;
        }

        DrawableByVulkan[] nested;

        foreach(record; parts)
            if(record.nested !is null)
            {
                bool seen;

                foreach(drawable; nested)
                    if(drawable is record.nested)
                    {
                        seen = true;
                        break;
                    }

                if(!seen)
                    nested ~= record.nested;
            }

        foreach(drawable; nested)
        {
            if(used >= budget)
                break;

            if(auto perPart = cast(PartDrawable) drawable)
                used += perPart.uploadParts(buf, budget - used);
        }

        return used;
    }

    void releaseParts(scope const(size_t)[] keys)
    {
        registerParts();

        static struct NestedGroup
        {
            DrawableByVulkan drawable;
            size_t[] keys;
        }

        PbrMesh[] released;
        NestedGroup[] groups;

        foreach(key; keys)
        {
            auto record = &parts[key];

            if(record.mesh is null)
            {
                size_t found = groups.length;

                foreach(g, group; groups)
                    if(group.drawable is record.nested)
                    {
                        found = g;
                        break;
                    }

                if(found == groups.length)
                    groups ~= NestedGroup(record.nested);

                groups[found].keys ~= record.nestedKey;

                continue;
            }

            auto refs = record.mesh in meshRefs;

            assert(refs !is null && *refs > 0, "releasing a part nothing holds");

            if(--*refs == 0)
            {
                // A mesh that never uploaded holds no piece references
                if(meshReady.get(record.mesh, false))
                    released ~= record.mesh;

                meshReady.remove(record.mesh);
            }
        }

        foreach(mesh; released)
            foreach(piece; mesh.pieces)
            {
                assert(pieceRefs[piece] > 0, "releasing a piece nothing holds");

                if(--pieceRefs[piece] == 0)
                    gpuBuffs[piece].releaseGPU();
            }

        foreach(group; groups)
            if(auto perPart = cast(PartDrawable) group.drawable)
                perPart.releaseParts(group.keys);
    }

    string partName(size_t key)
    {
        registerParts();

        const record = &parts[key];

        if(record.mesh !is null)
            return record.mesh.name.length ? record.mesh.name : name;

        if(record.nestedKey == wholePart)
        {
            if(auto scene = cast(GodotScene) record.nested)
                return scene.name;

            if(auto gltf = cast(GlTF) record.nested)
                return gltf.possibleName;

            return name;
        }

        if(auto perPart = cast(PartDrawable) record.nested)
            return perPart.partName(record.nestedKey);

        return name;
    }

    void eachPart(scope void delegate(in Part part) dg)
    {
        registerParts();

        foreach(i, record; parts)
            dg(Part(record.bounds, record.world, i));
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
