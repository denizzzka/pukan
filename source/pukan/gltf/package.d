module pukan.gltf;

import dlib.math;
public import pukan.gltf.loader: GltfAsset, LoadStats, createGltfInstance, loadGltfAsset;
public import pukan.gltf.factory: GltfFactory;
import pukan.pbr.accessor;
import pukan.gltf.animation: AnimationSupport;
import pukan.gltf.loader;
import pukan.pbr.pipelines: PbrPipelineVariants, PbrPipelines, LightingMode, lightingMode, oitPass, transmissionPass;
import pukan.gltf.material: applyGltfMaterial;
import pukan.pbr.mesh: PbrMesh, MeshClass = PbrMesh, IndicesDescr, MeshStreams;
import pukan.material: AlphaMode, Material, MaterialBuffer, MaterialMode, runtimeMaterialOverride;
import pukan.misc: Boxf;
import pukan.gltf.skin_matrices: SkinMatrices;
import pukan.tree: BaseNode = Node;
import pukan.vulkan.bindings;
import pukan.vulkan;
import std.algorithm;
import std.array;
import std.range;
import std.conv: to;
import std.exception: enforce;
import vibe.data.json;

alias LoaderNode = pukan.gltf.loader.Node;

private bool isSkinAnimated(GltfContent content, LoaderNode[] nodes)
{
    if(content.skins.length == 0 || content.animations.length == 0)
        return false;

    int[] parents;
    parents.length = nodes.length;
    parents[] = -1;

    foreach(i, ref node; nodes)
        foreach(child; node.childrenNodeIndices)
            parents[child] = cast(int) i;

    bool[] animated;
    animated.length = nodes.length;

    foreach(ref animation; content.animations)
        foreach(ref channel; animation.channels)
            if(channel.targetNode < nodes.length)
                animated[channel.targetNode] = true;

    foreach(ref skin; content.skins)
        foreach(joint; skin.nodesIndices)
        {
            int current = cast(int) joint;

            while(current >= 0)
            {
                if(animated[current])
                    return true;

                current = parents[current];
            }
        }

    return false;
}

private Boxf accessorAabb(in Accessor accessor)
{
    if(accessor.min_max == Json.emptyObject)
        return Boxf.init;

    return Boxf(
        Vector3f(accessor.min_max["min"].deserializeJson!(float[3])),
        Vector3f(accessor.min_max["max"].deserializeJson!(float[3])),
    );
}

struct Trans
{
    Vector3f transl;
    Quaternionf rot;
    Vector3f scale;

    static Trans identity()
    {
        Trans r;
        r.transl = Vector3f(0, 0, 0);

        return r;
    }

    Matrix4x4f calcMatrix() /*const*/
    {
        //TODO: perfomance of this calculations can be increased
        import std.math.traits: isNaN;

        Matrix4x4f r = Matrix4x4f.identity;

        if(!transl.x.isNaN) r *= transl.translationMatrix;
        if(!rot.x.isNaN) r *= rot.toMatrix4x4;
        if(!scale.x.isNaN) r *= scale.scaleMatrix;

        return r;
    }
}

class Node : BaseNode
{
    NodePayload payload;
    alias this = payload;

    Trans* trans;
    package Matrix4x4f* transFromRoot; // used for skin calculation
    MeshClass[] meshes;

    this(NodePayload pa)
    {
        payload = pa;
    }

    void traversal(void delegate(Node) dg)
    {
        super.traversal((n){
            dg(cast(Node) n);
        });
    }

    /// For correct result must be called on root node only
    package void refreshTransFromRootValues()
    {
        import std.math;
        import std;

        traversal((node){
            // is root scene node?
            if(node.transFromRoot is null)
                return; // just ignore - root scene doesn't have assigned transFromRoot pointer

            assert(node.parent !is null);
            auto parentTransFromRoot = (cast(Node) node.parent).transFromRoot;

            // parent is root scene node?
            if(parentTransFromRoot is null)
                *node.transFromRoot = node.trans.calcMatrix;
            else
            {
                assert(!(*parentTransFromRoot)[0].isNaN);
                *node.transFromRoot = *parentTransFromRoot * node.trans.calcMatrix;
            }
        });
    }
}

class GlTF : DrawableByVulkan, Blended
{
    LoadStats loadStats;

    /// Mirrors the model for the project's inverted view; turn off for nesting
    bool flipWinding = true;

    private bool uploaded;
    private bool skinsBaked;

    private Node rootSceneNode;
    private Trans rootSceneNodeTrans;

    package GltfContent content;
    alias this = content;

    package GltfAsset asset;
    private VkDescriptorImageInfo[] texturesDescrInfos;
    private VkDescriptorImageInfo fakeTextureInfo;
    private VkBuffer vertexFallback;
    private GltfLoadOptions loadOptions;
    private PbrPipelines pipelines;

    private MeshClass[] meshes;

    static if(runtimeMaterialOverride)
        private Material[] authoredMaterials;
    private DescriptorAllocator allocator;
    private MaterialBuffer materialBuffer;

    version(assert)
        package ReadableTransferBuffer[] jointMatricesBufs;
    else
        package TransferBuffer[] jointMatricesBufs;

    private VkDescriptorBufferInfo[] jointsUboInfos;

    /// Node transforms in glTF root space, shared by every skin
    protected Matrix4x4f[] nodeTransforms;

    private Trans[] baseNodeTranslations;
    private AnimationSupport animation;

    // TODO: create GlTF class which uses LoaderNode[] as base for internal tree for faster loading
    // The downside of this is that such GlTF characters will not be able to pick up objects in their hands and so like.
    package this(
        ref PbrPipelines pipelines,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        LogicalDevice device,
        GltfAsset asset,
        Texture fakeTexture,
        VkBuffer vertexFallback,
        GltfLoadOptions loadOptions,
    )
    {
        this.loadOptions = loadOptions;
        this.pipelines = pipelines;
        this.allocator = allocator;
        this.materialBuffer = materialBuffer;
        this.vertexFallback = vertexFallback;
        this.asset = asset;
        content = asset.content;

        fakeTextureInfo = VkDescriptorImageInfo(
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            imageView: fakeTexture.imageView,
            sampler: fakeTexture.sampler,
        );

        assert(content.meshes.length > 0);

        animation = AnimationSupport(&content, asset.nodes.length);
        skinsBaked = content.skins.length > 0 && !isSkinAnimated(content, asset.nodes);

        {
            baseNodeTranslations.length = asset.nodes.length;

            foreach(i, ref node; asset.nodes)
                baseNodeTranslations[i] = node.trans;

            // Vaules if object is not animated:
            animation.perNodeTranslations[0 .. $] = baseNodeTranslations;
        }

        {
            initJointMatricesBuffer(device, asset.nodes);

            Node createNodeHier(ref LoaderNode ln)
            {
                auto nn = new Node(ln.payload);

                foreach(idx; ln.childrenNodeIndices)
                {
                    auto c = createNodeHier(asset.nodes[idx]);
                    c.trans = &animation.perNodeTranslations[idx];

                    setupNodeTransFromRoot(c, idx);

                    nn.addChildNode(c);
                }

                return nn;
            }

            this.rootSceneNode = createNodeHier(asset.rootSceneNode);
            this.rootSceneNodeTrans = asset.rootSceneNode.trans;
            this.rootSceneNode.trans = &rootSceneNodeTrans;
        }

        // Textures:
        {
            if(textures.length == 0)
            {
                /*
                A fake texture is only needed if there are no textures
                at all to substitute texture data that is unconditionally
                passed to the shader.
                */
                texturesDescrInfos.length = 1;
                texturesDescrInfos[0] = fakeTextureInfo;
            }
            else
            {
                texturesDescrInfos.length = textures.length;

                foreach(i, ref descrInfo; texturesDescrInfos)
                    descrInfo = VkDescriptorImageInfo(
                        imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                        imageView: textures[i].imageView,
                        sampler: textures[i].sampler,
                    );
            }
        }

        // Baked skins need the bind-pose joint transforms.
        this.rootSceneNode.refreshTransFromRootValues;

        this.rootSceneNode.traversal((node){
            setUpEachNode(node, device);
        });
    }

    protected void initJointMatricesBuffer(LogicalDevice device, LoaderNode[] nodes)
    {
        // A file without skins still binds MATERIAL_JOINTS in the shader
        Matrix4x4f[] identityBuf;
        identityBuf.length = nodes.length;
        identityBuf[0..$] = Matrix4x4f.identity;

        auto buffer = createJointMatricesBuf(device, identityBuf.length);
        buffer.cpuBuf[0 .. $] = identityBuf;

        jointMatricesBufs = [buffer];
        jointsUboInfos = [jointMatricesInfo(buffer)];
    }

    private static auto createJointMatricesBuf(LogicalDevice device, size_t jointsCount)
    {
        version(assert)
            return device.create!ReadableTransferBuffer(Matrix4x4f.sizeof * jointsCount, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        else
            return device.create!TransferBuffer(Matrix4x4f.sizeof * jointsCount, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
    }

    private static VkDescriptorBufferInfo jointMatricesInfo(TransferBuffer buffer)
    {
        return VkDescriptorBufferInfo(
            buffer: buffer.gpuBuffer,
            offset: 0,
            range: buffer.length,
        );
    }

    protected void setupNodeTransFromRoot(Node node, size_t idx)
    {
        // no skin in base GlTF
    }

    ~this()
    {
        foreach(ref buffer; jointMatricesBufs)
            if(buffer)
                destroy(buffer);
    }

    string possibleName() const
    {
        if(rootSceneNode.name.length)
            return rootSceneNode.name;

        //looking for first mesh name
        foreach(m; meshes)
            if(m.name.length)
                return m.name;

        // no name found
        return null;
    }

    bool isAnimated() const => animation.animations.length > 0;

    /// Turns the model mirror off for an instance nested in another scene
    void setFlipWinding(bool value)
    {
        flipWinding = value;

        // The mirror and the project's flipped view cancel out, so the winding stays as authored
        foreach(mesh; meshes)
            mesh.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    }

    static if(runtimeMaterialOverride)
    {
        /// Applies one material to every mesh, remembering the authored ones
        void setMaterialOverride(Material material)
        {
            if(authoredMaterials.length != meshes.length)
            {
                authoredMaterials.length = meshes.length;

                foreach(i, mesh; meshes)
                    authoredMaterials[i] = mesh.material;
            }

            foreach(mesh; meshes)
                mesh.setMaterial(material);
        }

        /// Restores the materials the file declared
        void clearMaterialOverride()
        {
            foreach(i, mesh; meshes)
                if(i < authoredMaterials.length)
                    mesh.setMaterial(authoredMaterials[i]);
        }
    }

    auto calcAABB() const
    {
        import pukan.misc: Boxf;

        Boxf r;

        foreach(m; meshes)
            m.calcAABB(asset.gpuBuffs, r);

        return r;
    }

    //TODO: private
    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        import core.time: MonoTime;

        if(uploaded)
            return;

        auto start = MonoTime.currTime;

        commandPool.recordOneTimeAndSubmit(commandBuffer, (buf) {
            foreach(ref piece; asset.gpuBuffs[asset.uploadedBuffers .. $])
                if(piece)
                    piece.recordUpload(buf);

            asset.uploadedBuffers = asset.gpuBuffs.length;

            materialBuffer.recordUpload(buf);

            uploadSkinMatricesStatic(buf);
        });

        loadStats.uploadNs += cast(ulong) (MonoTime.currTime - start).total!"nsecs";

        foreach(ref mesh; meshes)
            mesh.updateDescriptorSetsAndUniformBuffers(device);

        uploaded = true;
    }

    private void setUpEachNode(ref Node node, LogicalDevice device)
    {
        // Node without mesh attached
        if(node.meshIdx < 0) return;

        const mesh = &content.meshes[node.meshIdx];

        foreach(primitive; mesh.primitives)
        {
            auto m = createPrimitiveMesh(device, *mesh, primitive, node.skinIdx);
            node.meshes ~= m;
            meshes ~= m;
        }
    }

    private MeshClass createPrimitiveMesh(
        LogicalDevice device,
        in Mesh mesh,
        in Primitive primitive,
        int skinIdx,
    )
    {
        MeshStreams uplVert;

        {
            const vertIdx = primitive.attributes["POSITION"].get!ushort;
            auto vertices = &accessors[vertIdx];

            enforce(vertices.count > 0);
            debug assert(vertices.type == "VEC3");
            enforce(vertices.componentType == ComponentType.FLOAT);

            import dlib.math: Vector3f;
            static assert(Vector3f.sizeof == float.sizeof * 3);

            uplVert.vertices = content.getAccess!(Type.VEC3, Vector3f)(*vertices);
            uplVert.aabb = accessorAabb(*vertices);
        }

        const vertexCount = uplVert.vertices.count;
        bool hasSkin = ("WEIGHTS_0" in primitive.attributes) !is null;

        if(hasSkin)
        {
            const jointAccessor = accessors[primitive.attributes["JOINTS_0"].get!uint];

            if(jointAccessor.componentType == ComponentType.UNSIGNED_BYTE)
            {
                alias Vector4ub = Vector!(ubyte, 4);

                const access = content.getAccess!(Type.VEC4, Vector4ub)(jointAccessor);
                auto range = content.rangify!Vector4ub(access);

                Vector4us[] joints;
                joints.length = jointAccessor.count;

                foreach(i; 0 .. jointAccessor.count)
                {
                    const joint = range[i];
                    joints[i] = Vector4us(joint.x, joint.y, joint.z, joint.w);
                }

                uplVert.joints = createVertexBuffer(device, joints, asset.gpuBuffs);
            }
            else
                uplVert.joints = content.getAccess!(Type.VEC4, Vector4us)(jointAccessor);

            uplVert.weights = content.getAccess!(Type.VEC4, Vector4f)(
                primitive.attributes["WEIGHTS_0"].get!uint
            );
        }

        const hasNormals = ("NORMAL" in primitive.attributes) !is null;
        if(hasNormals)
        {
            const normalIdx = primitive.attributes["NORMAL"].get!ushort;
            auto normals = &accessors[normalIdx];

            enforce(normals.count > 0);
            debug assert(normals.type == "VEC3");
            enforce(normals.componentType == ComponentType.FLOAT);

            uplVert.normals = content.getAccess!(Type.VEC3, Vector3f)(*normals);
        }
        // If indexed mesh:
        if(primitive.indicesAccessorIdx >= 0)
        {
            auto indices = accessors[ primitive.indicesAccessorIdx ];

            debug enforce(indices.type == Type.SCALAR, indices.type);

            if(indices.componentType == ComponentType.UNSIGNED_BYTE)
            {
                const byteAccess = content.getAccess(indices);
                auto range = AccessRange!(ubyte, false)(content.bufferViews[byteAccess.viewIdx].buf, byteAccess);
                ushort[] widened;

                foreach(value; range)
                    widened ~= value;

                const widenedAccess = createVertexBuffer(device, widened, asset.gpuBuffs, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
                uplVert.indices = IndicesDescr(widenedAccess, VK_INDEX_TYPE_UINT16);
            }
            else
            {
                const indicesAccessor = content.getAccess(indices);
                createGpuBufIfNeed(device, indicesAccessor, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);

                uplVert.indices = IndicesDescr(indicesAccessor, indices.componentType == ComponentType.UNSIGNED_INT ? VK_INDEX_TYPE_UINT32 : VK_INDEX_TYPE_UINT16);
            }
        }

        enforce(!("TEXCOORD_1" in primitive.attributes), "not supported");

        const hasTexCoords = ("TEXCOORD_0" in primitive.attributes) !is null;
        if(hasTexCoords)
        {
            const texCoordsIdx = primitive.attributes["TEXCOORD_0"].get!ushort;
            auto texCoords = &accessors[texCoordsIdx];

            enforce(texCoords.count > 0);
            debug assert(texCoords.type == "VEC2");
            debug assert(texCoords.componentType == ComponentType.FLOAT);

            uplVert.texCoords = content.getAccess!(Type.VEC2, Vector2f)(*texCoords);
            createGpuBufIfNeed(device, uplVert.texCoords, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        }

        const hasVertexColors = ("COLOR_0" in primitive.attributes) !is null;
        if(hasVertexColors)
        {
            const colorIdx = primitive.attributes["COLOR_0"].get!ushort;
            auto colors = &accessors[colorIdx];
            enforce(colors.count == vertexCount);
            debug assert(colors.type == Type.VEC3 || colors.type == Type.VEC4);

            const view = content.bufferViews[colors.viewIdx];
            const stride = view.stride ? view.stride : colors.typeSizeOf;
            const ubyte* data = view.buf.ptr + colors.offset;

            uint[] packed;
            packed.length = colors.count;

            float component(const ubyte* p, size_t index) const
            {
                with(ComponentType)
                switch(colors.componentType)
                {
                    case FLOAT:          return (cast(const float*) p)[index];
                    case UNSIGNED_BYTE:  return p[index] / 255.0f;
                    case UNSIGNED_SHORT: return (cast(const ushort*) p)[index] / 65535.0f;
                    default: assert(0);
                }
            }

            foreach(i; 0 .. colors.count)
            {
                const p = data + i * stride;
                const a = colors.type == Type.VEC4 ? component(p, 3) : 1.0f;
                packed[i] =
                    packColorComponent(component(p, 0)) |
                    (packColorComponent(component(p, 1)) << 8) |
                    (packColorComponent(component(p, 2)) << 16) |
                    (packColorComponent(a) << 24);
            }

            uplVert.colors = createVertexBuffer(device, packed, asset.gpuBuffs);
        }

        // Tangent data is only needed when a normal map samples it
        const hasTangents = hasNormals
            && hasTexCoords
            && hasNormalTexture(primitive.material)
            && ("TANGENT" in primitive.attributes) !is null;

        if(hasTangents)
        {
            const tangentIdx = primitive.attributes["TANGENT"].get!ushort;
            auto tangents = &accessors[tangentIdx];

            enforce(tangents.count > 0);
            debug assert(tangents.type == "VEC4");
            enforce(tangents.componentType == ComponentType.FLOAT);

            uplVert.tangents = content.getAccess!(Type.VEC4, Vector4f)(*tangents);
        }

        if(hasSkin && skinsBaked)
        {
            enforce(skinIdx >= 0, "a skinned primitive needs a node with a skin");

            const jointMatrices = content.skins[skinIdx].calculateJointMatrices(nodeTransforms);

            Vector3f[] bakedPositions;
            bakedPositions.length = vertexCount;

            auto positionRange = AccessRange!(Vector3f, false)(
                content.bufferViews[uplVert.vertices.viewIdx].buf,
                uplVert.vertices,
            );
            auto jointRange = AccessRange!(Vector4us, false)(
                content.bufferViews[uplVert.joints.viewIdx].buf,
                uplVert.joints,
            );
            auto weightRange = AccessRange!(Vector4f, false)(
                content.bufferViews[uplVert.weights.viewIdx].buf,
                uplVert.weights,
            );

            foreach(i; 0 .. vertexCount)
            {
                const p = positionRange.front;
                positionRange.popFront;
                const j = jointRange.front;
                jointRange.popFront;
                const w = weightRange.front;
                weightRange.popFront;

                const baked = Vector4f(p.x, p.y, p.z, 1) * skinMatrix(jointMatrices, j, w);
                bakedPositions[i] = Vector3f(baked.x, baked.y, baked.z);
            }

            if(hasNormals)
            {
                Vector3f[] bakedNormals;
                bakedNormals.length = vertexCount;

                auto normalRange = AccessRange!(Vector3f, false)(
                    content.bufferViews[uplVert.normals.viewIdx].buf,
                    uplVert.normals,
                );
                auto normalJointRange = AccessRange!(Vector4us, false)(
                    content.bufferViews[uplVert.joints.viewIdx].buf,
                    uplVert.joints,
                );
                auto normalWeightRange = AccessRange!(Vector4f, false)(
                    content.bufferViews[uplVert.weights.viewIdx].buf,
                    uplVert.weights,
                );

                foreach(i; 0 .. vertexCount)
                {
                    const n = normalRange.front;
                    normalRange.popFront;
                    const j = normalJointRange.front;
                    normalJointRange.popFront;
                    const w = normalWeightRange.front;
                    normalWeightRange.popFront;

                    const baked = Vector4f(n.x, n.y, n.z, 0) * skinMatrix(jointMatrices, j, w);
                    bakedNormals[i] = Vector3f(baked.x, baked.y, baked.z).normalized;
                }

                uplVert.normals = createVertexBuffer(device, bakedNormals, asset.gpuBuffs);
            }

            if(hasTangents)
            {
                Vector4f[] bakedTangents;
                bakedTangents.length = vertexCount;

                auto tangentRange = AccessRange!(Vector4f, false)(
                    content.bufferViews[uplVert.tangents.viewIdx].buf,
                    uplVert.tangents,
                );
                auto tangentJointRange = AccessRange!(Vector4us, false)(
                    content.bufferViews[uplVert.joints.viewIdx].buf,
                    uplVert.joints,
                );
                auto tangentWeightRange = AccessRange!(Vector4f, false)(
                    content.bufferViews[uplVert.weights.viewIdx].buf,
                    uplVert.weights,
                );

                foreach(i; 0 .. vertexCount)
                {
                    const t = tangentRange.front;
                    tangentRange.popFront;
                    const j = tangentJointRange.front;
                    tangentJointRange.popFront;
                    const w = tangentWeightRange.front;
                    tangentWeightRange.popFront;

                    const baked = Vector4f(t.x, t.y, t.z, 0) * skinMatrix(jointMatrices, j, w);
                    const n = Vector3f(baked.x, baked.y, baked.z).normalized;
                    bakedTangents[i] = Vector4f(n.x, n.y, n.z, t.w);
                }

                uplVert.tangents = createVertexBuffer(device, bakedTangents, asset.gpuBuffs);
            }

            uplVert.vertices = createVertexBuffer(device, bakedPositions, asset.gpuBuffs);

            uplVert.aabb = Boxf.init;
            hasSkin = false;
        }
        else
        {
            createGpuBufIfNeed(device, uplVert.vertices, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

            if(hasNormals)
                createGpuBufIfNeed(device, uplVert.normals, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

            if(hasTangents)
                createGpuBufIfNeed(device, uplVert.tangents, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

            if(hasSkin)
            {
                createGpuBufIfNeed(device, uplVert.joints, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
                createGpuBufIfNeed(device, uplVert.weights, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            }
        }

        // Every mesh binds MATERIAL_JOINTS; without a skin the shader ignores it
        VkDescriptorBufferInfo jointsUboInfo = jointsUboInfos[skinIdx >= 0 ? skinIdx : 0];

        auto m = new PbrMesh(
            mesh.name,
            uplVert,
            allocator,
            materialBuffer,
            fakeTextureInfo,
            hasSkin,
            vertexFallback,
            jointsUboInfo,
        );

        applyGltfMaterial(m, primitive.material, texturesDescrInfos, hasTexCoords, hasNormals, hasTangents, hasVertexColors, loadOptions);
        m.buildGeometry(asset.gpuBuffs);
        return m;
    }

    private static bool hasNormalTexture(in Json json)
    {
        return json.type == Json.Type.object && ("normalTexture" in json) !is null;
    }

    private static ubyte packColorComponent(float value)
    {
        import std.algorithm: max, min;
        return cast(ubyte) (min(max(value, 0.0f), 1.0f) * 255.0f + 0.5f);
    }

    private static Matrix4x4f skinMatrix(
        const Matrix4x4f[] jointMatrices,
        Vector4us joints,
        Vector4f weights,
    )
    {
        Matrix4x4f result = jointMatrices[joints.x] * weights.x;
        result += jointMatrices[joints.y] * weights.y;
        result += jointMatrices[joints.z] * weights.z;
        result += jointMatrices[joints.w] * weights.w;

        return result;
    }

    private BufAccess createVertexBuffer(T)(
        LogicalDevice device,
        T[] data,
        ref BufferPieceOnGPU[] gpuBuffs,
        VkBufferUsageFlags usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
    )
    {
        auto piece = new BufferPieceOnGPU;
        piece.buffer = new TransferBuffer(device, T.sizeof * data.length, usage);
        (cast(T[]) piece.buffer.cpuBuf)[] = data;
        gpuBuffs ~= piece;

        return BufAccess(cast(ptrdiff_t)(gpuBuffs.length - 1), 0, cast(ubyte) T.sizeof, cast(uint) data.length);
    }

    private auto createGpuBufIfNeed(LogicalDevice device, in BufAccess ac, VkBufferUsageFlags flags)
    {
        if(asset.gpuBuffs[ac.viewIdx] is null)
            asset.gpuBuffs[ac.viewIdx] = content.bufferViews[ac.viewIdx].createGPUBuffer(device, flags);

        return &asset.gpuBuffs[ac.viewIdx];
    }

    void refreshBuffers(VkCommandBuffer buf)
    {
        if(isAnimated)
        {
            animation.currTime += 0.005;
            applyAnimation();
            rootSceneNode.refreshTransFromRootValues;
        }

        refreshSkinMatrices(buf);

        foreach(e; meshes)
            e.refreshBuffers(buf);
    }

    private void applyAnimation()
    {
        animation.setPose(&animations[$-1], baseNodeTranslations);
    }

    bool isBlended() const
    {
        foreach(mesh; meshes)
            if(mesh.alphaMode == AlphaMode.blend)
                return true;

        return false;
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
            MeshClass mesh;
            Matrix4x4f trans;
            float depth;
        }

        //TODO: not need to call this recursive - just call it in row and use fromSkinRootNodeTranslations to get coords
        void collectDraws(Matrix4x4f trans, Node node, ref MeshDraw[] draws)
        {
            assert(node.trans !is null);

            trans *= node.trans.calcMatrix;

            foreach(mesh; node.meshes)
            {
                const clip = Vector4f(0, 0, 0, 1) * trans;
                draws ~= MeshDraw(mesh, trans, clip.w);
            }

            foreach(c; node.children)
                collectDraws(trans, cast(Node) c, draws);
        }

        // A nested glTF uses its meshes' clockwise front face instead
        if(flipWinding)
            trans *= Vector3f(-1, -1, -1).scaleMatrix;

        MeshDraw[] draws;
        collectDraws(trans, rootSceneNode, draws);

        // Back to front only matters for the in-place blend path
        if(phase == DrawPhase.blended)
            draws.sort!((a, b) => a.depth > b.depth);

        foreach(draw; draws)
            if(matchesPhase(draw.mesh, phase))
                draw.mesh.draw(buf, selectPipeline(draw.mesh, phase), draw.trans, frameSet);
    }

    private static bool matchesPhase(const MeshClass mesh, DrawPhase phase)
    {
        const blended = mesh.alphaMode == AlphaMode.blend;
        const transmissive = mesh.material.transmission.x > 0.0f;
        // Without its own pass, a transmissive mesh draws where the opaque ones do
        const ownPass = transmissive && transmissionPass;

        if(phase == DrawPhase.transmission)
            return transmissive;

        if(phase == DrawPhase.blended)
            return blended && !ownPass;

        if(phase == DrawPhase.shadow)
            return !blended && !transmissive && mesh.alphaMode == AlphaMode.opaque;

        return !blended && !ownPass;
    }


    private GraphicsPipelineCfg selectPipeline(const MeshClass mesh, DrawPhase phase)
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

    private static GraphicsPipelineCfg selectVariant(PbrPipelineVariants variants, const MeshClass mesh)
    {
        if(mesh.alphaMode == AlphaMode.blend)
        {
            if(oitPass)
                return mesh.doubleSided ? variants.doubleSidedOit : variants.oit;

            return mesh.doubleSided ? variants.doubleSidedBlend : variants.blend;
        }

        return mesh.doubleSided ? variants.doubleSided : variants.opaque;
    }

    protected void uploadSkinMatricesStatic(scope VkCommandBuffer commandBuffer)
    {
    }

    protected void refreshSkinMatrices(VkCommandBuffer buf)
    {
        foreach(ref buffer; jointMatricesBufs)
            buffer.recordUpload(buf);
    }
}

class SkinnedGlTF : GlTF
{
    package this(
        ref PbrPipelines pipelines,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        LogicalDevice device,
        GltfAsset asset,
        Texture fakeTexture,
        VkBuffer vertexFallback,
        GltfLoadOptions loadOptions,
    )
    {
        super(pipelines, allocator, materialBuffer, device, asset, fakeTexture, vertexFallback, loadOptions);
    }

    protected override void initJointMatricesBuffer(LogicalDevice device, LoaderNode[] nodes)
    {
        nodeTransforms.length = nodes.length;

        // A skin is placed by the node that references it, so its inverse is
        // taken from the first such node
        foreach(i, ref node; nodes)
            if(node.skinIdx >= 0 && content.skins[node.skinIdx].skinRootNodeIdx < 0)
                content.skins[node.skinIdx].skinRootNodeIdx = cast(int) i;

        jointMatricesBufs.length = content.skins.length;
        jointsUboInfos.length = content.skins.length;

        foreach(i, ref skin; content.skins)
        {
            auto buffer = createJointMatricesBuf(device, skin.nodesIndices.length);
            assert(buffer.length > 0);

            jointMatricesBufs[i] = buffer;
            jointsUboInfos[i] = jointMatricesInfo(buffer);
        }
    }

    protected override void setupNodeTransFromRoot(Node node, size_t idx)
    {
        node.transFromRoot = &nodeTransforms[idx];
    }

    protected override void refreshSkinMatrices(VkCommandBuffer buf)
    {
        if(skinsBaked)
            return;

        recalcSkin();

        foreach(ref buffer; jointMatricesBufs)
            buffer.recordUpload(buf);
    }

    private void recalcSkin()
    {
        // TODO: move animated skin matrix updates to the GPU.
        assert(content.skins.length > 0);

        foreach(i, ref skin; content.skins)
        {
            assert(jointMatricesBufs[i].length > 0);
            jointMatricesBufs[i].cpuBuf[0 .. $] = skin.calculateJointMatrices(nodeTransforms);
        }
    }
}

/// Uses GPU to calculate skin joints
class SkinnedGlTF_skinJointsGPU : SkinnedGlTF
{
    package SkinMatrices[] skinMatrices;

    package this(
        ref PbrPipelines pipelines,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        LogicalDevice device,
        GltfAsset asset,
        Texture fakeTexture,
        VkBuffer vertexFallback,
        GltfLoadOptions loadOptions,
    )
    {
        super(pipelines, allocator, materialBuffer, device, asset, fakeTexture, vertexFallback, loadOptions);
    }

    protected override void initJointMatricesBuffer(LogicalDevice device, LoaderNode[] nodes)
    {
        super.initJointMatricesBuffer(device, nodes);

        if(skinsBaked)
            return;

        skinMatrices.length = content.skins.length;

        foreach(i, ref skin; content.skins)
        {
            Matrix4x4f[] invBindArr;
            invBindArr.length = skin.inverseBindMatrices.length;
            foreach(j; 0 .. invBindArr.length)
                invBindArr[j] = skin.inverseBindMatrices[j];

            skinMatrices[i] = new SkinMatrices(
                device,
                cast(uint) nodes.length,
                skin.nodesIndices,
                invBindArr,
                jointMatricesBufs[i].gpuBuffer,
                jointMatricesBufs[i].length,
            );
        }
    }

    protected override void refreshSkinMatrices(VkCommandBuffer buf)
    {
        if(skinsBaked)
            return;

        foreach(i, ref skin; content.skins)
        {
            Matrix4x4f skinRootInverse = Matrix4x4f.identity;
            if(skin.skinRootNodeIdx >= 0)
                skinRootInverse = nodeTransforms[skin.skinRootNodeIdx].inverse;

            skinMatrices[i].setTransFromRoot(nodeTransforms);
            skinMatrices[i].run(buf, skinRootInverse);
        }
    }

    protected override void uploadSkinMatricesStatic(scope VkCommandBuffer commandBuffer)
    {
        foreach(ref matrices; skinMatrices)
            if(matrices)
                matrices.recordStatic(commandBuffer);
    }

    /// Debug-only: downloads GPU-computed joint matrices and compares them against the CPU path.
    /// Must be called after submitting the command buffer that records `refreshBuffers`.
    version(assert)
    void debugVerifySkinJoints(LogicalDevice device, CommandPool commandPool, scope ref VkCommandBuffer commandBuffer)
    {
        if(skinsBaked)
            return;

        import std.math: abs;
        import std.algorithm: max;

        enum maxAllowedError = 1e-4;

        foreach(i, ref skin; content.skins)
        {
            jointMatricesBufs[i].downloadImmediate(commandPool, commandBuffer);

            auto gpuData = cast(const(float)[]) jointMatricesBufs[i].cpuBuf;
            auto cpuData = cast(const(float)[]) skin.calculateJointMatrices(nodeTransforms);

            assert(gpuData.length == cpuData.length);

            foreach(j; 0 .. gpuData.length)
            {
                const err = abs(gpuData[j] - cpuData[j]);
                assert(err < maxAllowedError, "joint matrix error " ~ err.to!string ~ " at " ~ j.to!string);
            }
        }
    }
}

///
alias Vector4us = Vector!(ushort, 4);
