module pukan.godot_scene.scene;

import dlib.math: Matrix4x4f, Vector2f, Vector3f, Vector4f;
import pukan.gltf: GlTF;
import pukan.godot_scene.environment: GodotEnvironment;
import pukan.graphics.common.misc: Boxf, hasBounds, isVisible, mergePartAabb;
import pukan.graphics.g3d.cell_index: Bounded, CellIndex, CulledParts, DrawItem, Part, PartDrawable, wholePart;
import pukan.graphics.g3d.cells: CellCoord;
import pukan.graphics.g3d.material: AlphaMode, Material, MaterialBuffer, MaterialMode;
import pukan.graphics.g3d.hlod: ProxyPiece, mergeGeometry, readGeometry;
import pukan.graphics.g3d.occlusion: DepthRaster, currentOcclusion;
import pukan.graphics.g3d.mesh: MeshResources, mirrors;
import pukan.graphics.g3d.pbr.accessor: BufAccess, BufferPieceOnGPU;
import pukan.graphics.g3d.pbr.culling: CullBatch, CullFrame, CullInstance, currentCullFrame;
import pukan.graphics.g3d.pbr.lod: clipDepth, generateLevels, lodThresholds, pickLevel;
import pukan.graphics.g3d.pbr.mesh: IndicesDescr, MeshGeometry, MeshStreams, PbrMesh;
import pukan.graphics.g3d.pbr.pipelines: LazyPipeline, LightingMode, PbrPipelineVariants, PbrPipelines, lightingMode, oitPass, plainShading, transmissionPass;
import pukan.physics.shapes: Collider, CollisionShape;
import pukan.physics.world: CollisionWorld;
import pukan.vulkan.bindings;
import pukan.vulkan.resources.sharing: SharedResource;
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
final class GodotScene : DrawableByVulkan, Blended, Bounded, PartDrawable, CulledParts, PipelineWarmup
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

    /// What a proxy needs for the attributes a merged piece leaves out
    private MeshResources resources;
    /// Merged geometry per cell, built the first time the cell is far
    private CellProxy[CellCoord] proxies;
    /// Parts a cell needs before a merge pays for the meshes it builds
    size_t proxyMinParts = 8;
    /// Cells that stay on the parts path, decided once
    private bool[CellCoord] sparseCells;

    /// Counts the parts that hold each mesh; the last one drops its pieces
    private SharedResource!PbrMesh[PbrMesh] meshNodes;
    /// GPU pieces several meshes share; the last holder releases the copy
    private SharedResource!BufferPieceOnGPU[] pieceNodes;

    /**
        What a far cell draws: one merged mesh per material, over its own pieces.

        TODO: the material descriptor sets come from the scene's allocator, which
        only dies with the scene, so a released cell leaves them behind.
    */
    private final class CellProxy
    {
        PbrMesh[] meshes;
        BufferPieceOnGPU[] pieces;
        /// Bytes the pieces of this proxy uploaded
        size_t bytes;
        /// Frames in flight may still read the pieces after the cell goes
        LogicalDevice device;

        ~this()
        {
            if(device is null)
                return;

            foreach(ref piece; pieces)
                if(piece && piece.buffer)
                    device.releaseQueue.retireHolder(piece.buffer);
        }
    }

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

    /// A mesh's instances of one phase, culled by the kernel before the pass
    private struct GatheredMesh
    {
        PbrMesh mesh;
        CullInstance[] instances;
        /// Clip-space placement of this scene, which sets the level thresholds
        Matrix4x4f trans;
        /// One batch per level, finest first
        CullBatch[] batches;
    }

    /// A mesh the kernel cannot cull, drawn as before
    private struct GatheredDraw
    {
        PbrMesh mesh;
        Matrix4x4f trans;
    }

    private struct GatheredNested
    {
        DrawableByVulkan drawable;
        /// Clip-space placement of this scene
        Matrix4x4f trans;
        Matrix4x4f base;
        size_t[] keys;
    }

    private struct GatherPhase
    {
        bool started;
        GatheredMesh[] meshes;
        GatheredDraw[] draws;
        GatheredNested[] nested;
    }

    private GatherPhase[4] gatherPhases;

    package(pukan) this(
        PbrPipelines pipelines,
        LogicalDevice device,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        MeshResources resources,
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
        this.resources = resources;
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
        foreach(ref proxy; proxies)
            if(proxy)
                destroy(proxy);

        proxies = null;

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
                acquireMesh(record.mesh);

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

        pieceNodes.length = gpuBuffs.length;
        foreach(i, piece; gpuBuffs)
            pieceNodes[i] = new SharedResource!BufferPieceOnGPU(
                piece,
                (BufferPieceOnGPU piece) { piece.releaseGPU(); },
            );

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
            if(!record.mesh.geometryReady)
                continue;

            const mvp = trans * record.world;

            //TODO: cull skinned meshes by their posed bounds
            if(!record.mesh.hasSkin && !isVisible(record.mesh.localAABB, mvp))
                continue;

            // A part the coarse depth grid already covers stays out of the draw
            if(currentOcclusion !is null && currentOcclusion.hidden(record.bounds, mvp))
                continue;

            const clip = Vector4f(0, 0, 0, 1) * mvp;
            draws ~= MeshDraw(record.mesh, mvp, clip.w);
        }

        if(phase == DrawPhase.blended)
            draws.sort!((a, b) => a.depth > b.depth);

        if(phase == DrawPhase.surface || phase == DrawPhase.shadow)
        {
            static struct Batch
            {
                PbrMesh mesh;
                size_t level;
                Matrix4x4f[] transforms;
            }

            Batch[] batches;

            PbrMesh thresholdsMesh;
            float[] thresholds;

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

                if(draw.mesh !is thresholdsMesh)
                {
                    thresholds = meshThresholds(draw.mesh, trans);
                    thresholdsMesh = draw.mesh;
                }

                const level = pickLevel(thresholds, clipDepth(draw.trans));

                size_t found = batches.length;

                foreach(b, batch; batches)
                    if(batch.mesh is draw.mesh && batch.level == level)
                    {
                        found = b;
                        break;
                    }

                if(found == batches.length)
                    batches ~= Batch(draw.mesh, level);

                batches[found].transforms ~= draw.trans;
            }

            foreach(batch; batches)
                batch.mesh.drawBatch(buf, selectPipeline(batch.mesh, phase),
                    batch.transforms, frameSet, batch.level);
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

    void beginGather(DrawPhase phase)
    {
        registerParts();

        gatherPhases[cast(uint) phase] = GatherPhase(started: true);
    }

    void gatherParts(VkCommandBuffer buf, in Matrix4x4f trans, scope const(size_t)[] keys, DrawPhase phase)
    {
        auto gathered = &gatherPhases[cast(uint) phase];

        foreach(key; keys)
        {
            auto record = &parts[key];

            if(record.mesh is null)
            {
                size_t found = gathered.nested.length;

                foreach(g, group; gathered.nested)
                    if(group.drawable is record.nested && group.base == record.base)
                    {
                        found = g;
                        break;
                    }

                if(found == gathered.nested.length)
                    gathered.nested ~= GatheredNested(record.nested, trans, record.base);

                gathered.nested[found].keys ~= record.nestedKey;
                continue;
            }

            // A part whose pieces are not on the GPU yet has no buffer to bind
            if(!record.mesh.geometryReady)
                continue;

            if(!matchesPhase(record.mesh, phase))
                continue;

            const mvp = trans * record.world;

            // A part the coarse depth grid already covers stays out of the draw
            if(currentOcclusion !is null && currentOcclusion.hidden(record.bounds, mvp))
                continue;

            // A skinned mesh keeps the CPU path until its posed bounds are known
            if(record.mesh.hasSkin)
            {
                gathered.draws ~= GatheredDraw(record.mesh, mvp);
                continue;
            }

            size_t found = gathered.meshes.length;

            foreach(g, batch; gathered.meshes)
                if(batch.mesh is record.mesh)
                {
                    found = g;
                    break;
                }

            if(found == gathered.meshes.length)
                gathered.meshes ~= GatheredMesh(record.mesh, null, trans);

            gathered.meshes[found].instances ~= cullInstance(record.bounds, mvp);
        }
    }

    void endGather(VkCommandBuffer buf, DrawPhase phase)
    {
        auto gathered = &gatherPhases[cast(uint) phase];

        assert(currentCullFrame !is null, "gathering outside Scene recording");

        foreach(ref gatheredMesh; gathered.meshes)
        {
            if(gatheredMesh.instances.length == 0)
                continue;

            const instances = currentCullFrame.reserveInstances(gatheredMesh.instances);
            const thresholds = meshThresholds(gatheredMesh.mesh, gatheredMesh.trans);
            const levels = gatheredMesh.mesh.levelCount;

            gatheredMesh.batches.length = levels;

            foreach(level; 0 .. levels)
            {
                const maxDepth = level + 1 < levels ? thresholds[level + 1] : float.max;

                // The depth of a part is its origin's, which a part that holds
                // the camera can have behind it; the finest level takes those
                const minDepth = level == 0 ? -float.max : thresholds[level];

                gatheredMesh.batches[level] = currentCullFrame.reserveLevel(
                    instances, gatheredMesh.mesh.indexCount(level));
                currentCullFrame.dispatch(buf, instances, gatheredMesh.batches[level],
                    minDepth, maxDepth);
            }
        }
    }

    void drawGathered(VkCommandBuffer buf, VkDescriptorSet frameSet, DrawPhase phase)
    {
        auto gathered = &gatherPhases[cast(uint) phase];

        assert(gathered.started, "drawing a phase that was never gathered");

        foreach(draw; gathered.draws)
            draw.mesh.draw(buf, selectPipeline(draw.mesh, phase), draw.trans, frameSet);

        foreach(gatheredMesh; gathered.meshes)
            foreach(level, batch; gatheredMesh.batches)
                gatheredMesh.mesh.drawCulled(buf, selectPipeline(gatheredMesh.mesh, phase),
                    batch, frameSet, level);

        foreach(group; gathered.nested)
            if(auto perPart = cast(PartDrawable) group.drawable)
                perPart.drawParts(buf, group.trans * group.base, group.keys, frameSet, phase);
            else
                group.drawable.drawingBufferFilling(buf, group.trans * group.base, frameSet, phase);
    }

    /// Clip depth from which each level of the mesh is coarse enough
    private static float[] meshThresholds(const PbrMesh mesh, in Matrix4x4f trans)
    {
        float[] errors;
        errors.reserve(mesh.levelCount);

        foreach(level; 0 .. mesh.levelCount)
            errors ~= mesh.levelError(level);

        return lodThresholds(errors, trans);
    }

    /// Part bounds in the form the cull kernel reads; a part without bounds stays visible
    private static CullInstance cullInstance(in Boxf bounds, in Matrix4x4f mvp)
    {
        if(!hasBounds(bounds))
            return CullInstance(mvp, Vector4f(0, 0, 0, 1), Vector4f(0, 0, 0, 0));

        return CullInstance(
            mvp,
            Vector4f(bounds.min.x, bounds.min.y, bounds.min.z, 0),
            Vector4f(bounds.max.x, bounds.max.y, bounds.max.z, 0),
        );
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
                acquireMesh(record.mesh);
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

    /// Takes one holder of `mesh`; true when it is the first
    private bool acquireMesh(PbrMesh mesh)
    {
        auto node = mesh in meshNodes;

        if(node is null)
        {
            auto created = new SharedResource!PbrMesh(mesh, (PbrMesh released) {
                foreach(piece; released.pieces)
                    pieceNodes[piece].release();

                released.geometryReady = false;
            });

            meshNodes[mesh] = created;

            return created.acquire();
        }

        return (*node).acquire();
    }

    /// Drops one holder; the last one releases the pieces of the mesh
    private void releaseMesh(PbrMesh mesh)
    {
        auto node = mesh in meshNodes;

        assert(node !is null, "releasing a mesh nothing holds");
        (*node).release();

        if((*node).userCount == 0)
            meshNodes.remove(mesh);
    }

    /**
        Merges the static parts of `cell` into one mesh per material.

        A proxy is built once, from what the cell already holds: the CPU side of
        its pieces, so no decode happens twice. It is drawn instead of the cell's
        parts, and its index lists carry a coarse level for a distant view.

        Returns: bytes the proxy uploaded; zero when the cell already has one or
        a mesh of it is still waiting for its upload.
    */
    size_t buildProxy(CellCoord cell, CellIndex!DrawItem index, VkCommandBuffer buf)
    {
        registerParts();

        if(cell in proxies || cell in sparseCells)
            return 0;

        // Decoding waits for every part, so a half loaded cell costs nothing
        foreach(item; index.collect([cell]))
        {
            if(item.part == wholePart || !hasBounds(item.bounds))
                return 0;

            if(!partsReady([item.part]))
                return 0;
        }

        // A cell with a handful of parts keeps them: a merge costs a mesh and a
        // descriptor set per material and saves one draw per part
        size_t pieceCount;
        bool countable = true;

        void countPiece(GodotScene owner, PbrMesh mesh, in Matrix4x4f world)
        {
            ++pieceCount;
        }

        foreach(item; index.collect([cell]))
        {
            if(item.part == wholePart || !hasBounds(item.bounds))
            {
                countable = false;
                break;
            }

            collectPieces(this, [item.part], item.world, &countPiece, countable);
        }

        if(!countable || pieceCount < proxyMinParts)
        {
            sparseCells[cell] = true;
            return 0;
        }

        static struct Group
        {
            PbrMesh source;
            ProxyPiece[] pieces;
        }

        Group[] groups;
        MeshGeometry*[PbrMesh] decoded;
        const(void[])[][GodotScene] buffersOf;
        bool complete = true;

        void addPiece(GodotScene owner, PbrMesh mesh, in Matrix4x4f world)
        {
            auto geometry = mesh in decoded;

            if(geometry is null)
            {
                auto buffers = owner in buffersOf;

                if(buffers is null)
                {
                    buffersOf[owner] = owner.cpuBufs();
                    buffers = owner in buffersOf;
                }

                auto read = new MeshGeometry;
                *read = readGeometry(mesh.geometry.vert, *buffers);
                decoded[mesh] = read;
                geometry = mesh in decoded;

            }

            size_t found = groups.length;

            foreach(g, group; groups)
                if(group.source.sameMaterial(mesh))
                {
                    found = g;
                    break;
                }

            if(found == groups.length)
                groups ~= Group(mesh);

            groups[found].pieces ~= ProxyPiece(
                *geometry, world, mesh.frontFace != groups[found].source.frontFace);
        }

        foreach(item; index.collect([cell]))
        {
            // A part the cell does not bound stays out: a proxy stands for a cell
            if(item.part == wholePart || !hasBounds(item.bounds))
            {
                complete = false;
                continue;
            }

            collectPieces(this, [item.part], item.world, &addPiece, complete);
        }

        // A cell with a part the proxy cannot take keeps its parts
        if(!complete || groups.length == 0)
            return 0;

        auto proxy = new CellProxy;
        proxy.device = device;
        const cellBounds = index.grid.bounds(cell);

        foreach(group; groups)
        {
            auto merged = new MeshGeometry;
            *merged = mergeGeometry(group.pieces, cellBounds);

            if(merged.positions.length == 0)
                continue;


            if(auto mesh = createProxyMesh(proxy, *merged, group.source, buf))
                proxy.meshes ~= mesh;
        }

        if(proxy.meshes.length == 0)
        {
            destroy(proxy);
            return 0;
        }

        // The proxy meshes took new material slots, so the buffer carries them
        materialBuffer.recordUpload(buf);

        proxies[cell] = proxy;

        return proxy.bytes;
    }

    /// Whether every part behind `keys` is on the GPU, so a proxy can read it
    private bool partsReady(scope const(size_t)[] keys)
    {
        registerParts();

        foreach(key; keys)
        {
            ref record = parts[key];

            if(record.mesh !is null)
            {
                if(record.mesh.hasSkin || !record.mesh.geometryReady)
                    return false;

                continue;
            }

            auto nested = cast(GodotScene) record.nested;

            if(nested is null || !nested.partsReady([record.nestedKey]))
                return false;
        }

        return true;
    }

    /// CPU side of this scene's pieces, indexed like the buffers a mesh names
    private const(void[])[] cpuBufs()
    {
        void[][] result;
        result.length = gpuBuffs.length;

        foreach(i, piece; gpuBuffs)
            if(piece !is null && piece.buffer !is null)
                result[i] = piece.buffer.cpuBuf;

        return result;
    }

    /// Visits the parts behind `keys`, descending into the drawables this scene wraps
    private void collectPieces(
        GodotScene owner,
        scope const(size_t)[] keys,
        in Matrix4x4f trans,
        scope void delegate(GodotScene owner, PbrMesh mesh, in Matrix4x4f world) sink,
        ref bool complete,
    )
    {
        registerParts();

        foreach(key; keys)
        {
            ref record = parts[key];

            if(record.mesh !is null)
            {
                if(record.mesh.hasSkin || !record.mesh.geometryReady)
                {
                    complete = false;
                    continue;
                }

                sink(owner, record.mesh, trans * record.world);
                continue;
            }

            auto nested = cast(GodotScene) record.nested;

            // A drawable this scene cannot look into keeps its parts
            if(nested is null)
            {
                complete = false;
                continue;
            }

            nested.collectPieces(nested, [record.nestedKey], trans * record.base, sink, complete);
        }
    }

    /// Draws the cell's merged proxy; false when the cell has none
    bool drawProxy(
        VkCommandBuffer buf,
        CellCoord cell,
        in Matrix4x4f viewProj,
        VkDescriptorSet frameSet,
        DrawPhase phase,
    )
    {
        auto found = cell in proxies;

        if(found is null)
            return false;

        // The merged positions are in world space, so the view alone places them
        Matrix4x4f placement = viewProj;

        foreach(mesh; found.meshes)
        {
            if(!mesh.geometryReady || !matchesPhase(mesh, phase))
                continue;

            if(!isVisible(mesh.localAABB, viewProj))
                continue;

            mesh.drawBatch(buf, selectPipeline(mesh, phase), [placement], frameSet);
        }

        return true;
    }

    /// Whether the cell draws as a merged proxy
    bool hasProxy(CellCoord cell) const => (cell in proxies) !is null;

    /// Cells that a merge was worth
    size_t proxyCount() const => proxies.length;
    /// Cells that stay on the parts path because they hold too few parts
    size_t sparseCount() const => sparseCells.length;

    /// Drops the cell's proxy, freeing the pieces it uploaded
    void releaseProxy(CellCoord cell)
    {
        sparseCells.remove(cell);

        if((cell in proxies) is null)
            return;

        proxies.remove(cell);
    }

    /// Uploads the merged geometry and builds the mesh that draws it
    private PbrMesh createProxyMesh(
        ref CellProxy proxy,
        MeshGeometry geometry,
        PbrMesh source,
        VkCommandBuffer buf,
    )
    {
        MeshStreams streams;
        streams.vertices = addProxyPiece(proxy, geometry.positions, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, buf);
        streams.normals = addProxyPiece(proxy, geometry.normals, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, buf);
        streams.tangents = addProxyPiece(proxy, geometry.tangents, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, buf);
        streams.texCoords = addProxyPiece(proxy, geometry.texCoords, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, buf);
        streams.colors = addProxyPiece(proxy, geometry.colors, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, buf);
        streams.aabb = geometry.aabb;

        if(geometry.indices.length)
            streams.indices = IndicesDescr(
                addProxyPiece(proxy, geometry.indices, VK_BUFFER_USAGE_INDEX_BUFFER_BIT, buf),
                VK_INDEX_TYPE_UINT32,
            );

        auto mesh = new PbrMesh(
            source.name,
            streams,
            allocator,
            materialBuffer,
            VkDescriptorImageInfo.init,
            false,
            resources.fallbackVertex.buf,
            resources.identityJointsInfo,
        );

        // The proxy stands in for the source, so it takes its material as well
        mesh.copyMaterialFrom(source);
        mesh.updateDescriptorSetsAndUniformBuffers(device);

        // The merged triangles keep the winding the source mesh draws with
        mesh.frontFace = source.frontFace;

        mesh.buildGeometry(proxy.pieces);
        mesh.geometryReady = true;

        return mesh;
    }

    /// Uploads `data` as one piece of the cell's proxy and returns its accessor
    private BufAccess addProxyPiece(T)(
        ref CellProxy proxy,
        T[] data,
        VkBufferUsageFlags usage,
        VkCommandBuffer buf,
    )
    {
        if(data.length == 0)
            return BufAccess();

        auto piece = new BufferPieceOnGPU;
        piece.buffer = new TransferBuffer(device, T.sizeof * data.length, usage);
        (cast(T[]) piece.buffer.cpuBuf)[] = data;
        piece.recordUpload(buf);
        proxy.pieces ~= piece;
        proxy.bytes += T.sizeof * data.length;

        return BufAccess(
            cast(ptrdiff_t) (proxy.pieces.length - 1),
            0,
            cast(ubyte) T.sizeof,
            cast(uint) data.length,
        );
    }

    size_t uploadParts(VkCommandBuffer buf, size_t budget)
    {
        registerParts();

        size_t used;

        foreach(record; parts)
        {
            if(record.mesh is null || record.mesh.geometryReady)
                continue;

            if((record.mesh in meshNodes) is null)
                continue;

            size_t need;

            foreach(piece; record.mesh.pieces)
                if(!gpuBuffs[piece].isUploaded)
                    need += gpuBuffs[piece].buffer.length;

            // A mesh larger than the whole budget still uploads alone, so nothing stalls
            if(used > 0 && used + need > budget)
                continue;

            foreach(piece; record.mesh.pieces)
                if(pieceNodes[piece].acquire() && !gpuBuffs[piece].isUploaded)
                    gpuBuffs[piece].recordUpload(buf);

            record.mesh.buildGeometry(gpuBuffs);
            record.mesh.geometryReady = true;
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

            releaseMesh(record.mesh);
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
