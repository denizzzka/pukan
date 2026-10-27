module pukan.gltf;

import dlib.math;
public import pukan.gltf.loader: LoadStats, loadGlTF2;
public import pukan.gltf.factory: GltfFactory;
import pukan.gltf.accessor;
import pukan.gltf.animation: AnimationSupport;
import pukan.gltf.loader;
import pukan.gltf.pipelines: GltfPipelines;
import pukan.gltf.mesh: GltfMesh, MeshClass = GltfMesh, IndicesDescr, UploadedVertices;
import pukan.material: AlphaMode, MaterialBuffer;
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
    MeshClass mesh;

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

class GlTF : DrawableByVulkan
{
    LoadStats loadStats;

    private bool uploaded;

    private Node rootSceneNode;
    private Trans rootSceneNodeTrans;

    package GltfContent content;
    alias this = content;

    private BufferPieceOnGPU[] gpuBuffs;
    private VkDescriptorImageInfo[] texturesDescrInfos;
    private VkDescriptorImageInfo fakeTextureInfo;
    private GltfPipelines pipelines;

    private MeshClass[] meshes;
    private DescriptorAllocator allocator;
    private MaterialBuffer materialBuffer;

    version(assert)
        package ReadableTransferBuffer jointMatricesUniformBuf;
    else
        package TransferBuffer jointMatricesUniformBuf;

    private VkDescriptorBufferInfo jointsUboInfo;

    private Trans[] baseNodeTranslations;
    private AnimationSupport animation;

    // TODO: create GlTF class which uses LoaderNode[] as base for internal tree for faster loading
    // The downside of this is that such GlTF characters will not be able to pick up objects in their hands and so like.
    package this(
        ref GltfPipelines pipelines,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        LogicalDevice device,
        GltfContent cont,
        LoaderNode[] nodes,
        LoaderNode rootSceneNode,
        Texture fakeTexture,
    )
    {
        this.pipelines = pipelines;
        this.allocator = allocator;
        this.materialBuffer = materialBuffer;
        content = cont;

        fakeTextureInfo = VkDescriptorImageInfo(
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            imageView: fakeTexture.imageView,
            sampler: fakeTexture.sampler,
        );

        assert(content.meshes.length > 0);

        animation = AnimationSupport(&content, nodes.length);
        gpuBuffs.length = content.bufferViews.length;

        {
            baseNodeTranslations.length = nodes.length;

            foreach(i, ref node; nodes)
                baseNodeTranslations[i] = node.trans;

            // Vaules if object is not animated:
            animation.perNodeTranslations[0 .. $] = baseNodeTranslations;
        }

        {
            initJointMatricesBuffer(device, nodes);

            jointsUboInfo = VkDescriptorBufferInfo(
                buffer: jointMatricesUniformBuf.gpuBuffer,
                offset: 0,
                range: jointMatricesUniformBuf.length,
            );

            Node createNodeHier(ref LoaderNode ln)
            {
                auto nn = new Node(ln.payload);

                foreach(idx; ln.childrenNodeIndices)
                {
                    auto c = createNodeHier(nodes[idx]);
                    c.trans = &animation.perNodeTranslations[idx];

                    setupNodeTransFromRoot(c, idx);

                    nn.addChildNode(c);
                }

                return nn;
            }

            this.rootSceneNode = createNodeHier(rootSceneNode);
            this.rootSceneNodeTrans = rootSceneNode.trans;
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

        this.rootSceneNode.traversal((node){
            setUpEachNode(node, device);
        });

        // For skin support:
        this.rootSceneNode.refreshTransFromRootValues;
    }

    protected void initJointMatricesBuffer(LogicalDevice device, LoaderNode[] nodes)
    {
        //TODO: remove this fake buffer
        Matrix4x4f[] identityBuf;
        identityBuf.length = nodes.length;
        identityBuf[0..$] = Matrix4x4f.identity;

        version(assert)
            jointMatricesUniformBuf = device.create!ReadableTransferBuffer(Matrix4x4f.sizeof * identityBuf.length, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        else
            jointMatricesUniformBuf = device.create!TransferBuffer(Matrix4x4f.sizeof * identityBuf.length, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);

        jointMatricesUniformBuf.cpuBuf[0 .. $] = identityBuf;
    }

    protected void setupNodeTransFromRoot(Node node, size_t idx)
    {
        // no skin in base GlTF
    }

    ~this()
    {
        foreach(ref piece; gpuBuffs)
            if(piece && piece.buffer)
                destroy(piece.buffer);

        if(jointMatricesUniformBuf)
            destroy(jointMatricesUniformBuf);

        foreach(ref texture; content.textures)
            if(texture)
                destroy(texture);
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

    auto calcAABB() const
    {
        import pukan.misc: Boxf;

        Boxf r;

        foreach(m; meshes)
            m.calcAABB(gpuBuffs, r);

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
            foreach(ref piece; gpuBuffs)
                if(piece)
                    piece.recordUpload(buf);

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
        assert(mesh.primitives.length == 1, "FIXME: only one mesh primitive supported for now");

        const primitive = &mesh.primitives[0];

        UploadedVertices uplVert;

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

            createGpuBufIfNeed(device, uplVert.vertices, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        }

        const vertexCount = uplVert.vertices.count;

        if("WEIGHTS_0" in primitive.attributes)
        {
            uplVert.joints = content.getAccess!(Type.VEC4, Vector4us)(
                primitive.attributes["JOINTS_0"].get!uint
            );
            uplVert.weights = content.getAccess!(Type.VEC4, Vector4f)(
                primitive.attributes["WEIGHTS_0"].get!uint
            );

            createGpuBufIfNeed(device, uplVert.joints, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            createGpuBufIfNeed(device, uplVert.weights, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        }
        else
        {
            uplVert.joints = createFakeVertexBuffer!Vector4us(device, vertexCount, Vector4us.init, gpuBuffs);
            uplVert.weights = createFakeVertexBuffer!Vector4f(device, vertexCount, Vector4f(1, 0, 0, 0), gpuBuffs);
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
            createGpuBufIfNeed(device, uplVert.normals, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        }
        else
            uplVert.normals = createFakeVertexBuffer!Vector3f(device, vertexCount, Vector3f(0, 0, 1), gpuBuffs);

        // If indexed mesh:
        if(primitive.indicesAccessorIdx >= 0)
        {
            auto indices = accessors[ primitive.indicesAccessorIdx ];

            debug enforce(indices.type == Type.SCALAR, indices.type);

            const indicesAccessor = content.getAccess(indices);
            createGpuBufIfNeed(device, indicesAccessor, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);

            uplVert.indices = IndicesDescr(device, indicesAccessor, indices.componentType);
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

        auto m = new GltfMesh(
            mesh.name,
            uplVert,
            allocator,
            materialBuffer,
            fakeTextureInfo,
            gpuBuffs,
            jointsUboInfo,
        );

        m.applyMaterial(primitive.material, texturesDescrInfos, hasTexCoords, hasNormals);
        node.mesh = m;
        meshes ~= node.mesh;
    }

    private BufAccess createFakeVertexBuffer(T)(
        LogicalDevice device,
        uint count,
        T value,
        ref BufferPieceOnGPU[] gpuBuffs,
    )
    {
        auto piece = new BufferPieceOnGPU;
        piece.buffer = new TransferBuffer(device, T.sizeof * count, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        (cast(T[]) piece.buffer.cpuBuf)[] = value;
        gpuBuffs ~= piece;

        return BufAccess(cast(ptrdiff_t)(gpuBuffs.length - 1), 0, cast(ubyte) T.sizeof, count);
    }

    private auto createGpuBufIfNeed(LogicalDevice device, in BufAccess ac, VkBufferUsageFlags flags)
    {
        if(gpuBuffs[ac.viewIdx] is null)
            gpuBuffs[ac.viewIdx] = content.bufferViews[ac.viewIdx].createGPUBuffer(device, flags);

        return &gpuBuffs[ac.viewIdx];
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

    void drawingBufferFilling(VkCommandBuffer buf, Matrix4x4f trans)
    {
        // To avoid mirroring if loaded OpenGL mesh into Vulkan
        trans *= Vector3f(-1, -1, -1).scaleMatrix;

        drawingBufferFillingRecursive(buf, trans, rootSceneNode);
    }

    //TODO: not need to call this recursive - just call it in row and use fromSkinRootNodeTranslations to get coords
    private void drawingBufferFillingRecursive(VkCommandBuffer buf, Matrix4x4f trans, Node node)
    {
        import std.math;

        assert(node.trans !is null);

        trans *= node.trans.calcMatrix;

        if(node.mesh)
            node.mesh.draw(buf, selectPipeline(node.mesh), trans);

        foreach(c; node.children)
            drawingBufferFillingRecursive(buf, trans, cast(Node) c);
    }

    private GraphicsPipelineCfg selectPipeline(const MeshClass mesh)
    {
        if(mesh.doubleSided)
            return mesh.alphaMode == AlphaMode.blend ? pipelines.doubleSidedBlend : pipelines.doubleSided;

        return mesh.alphaMode == AlphaMode.blend ? pipelines.blend : pipelines.opaque;
    }

    protected void uploadSkinMatricesStatic(scope VkCommandBuffer commandBuffer)
    {
    }

    protected void refreshSkinMatrices(VkCommandBuffer buf)
    {
        jointMatricesUniformBuf.recordUpload(buf);
    }
}

class SkinnedGlTF : GlTF
{
    package this(
        ref GltfPipelines pipelines,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        LogicalDevice device,
        GltfContent cont,
        LoaderNode[] nodes,
        LoaderNode rootSceneNode,
        Texture fakeTexture,
    )
    {
        super(pipelines, allocator, materialBuffer, device, cont, nodes, rootSceneNode, fakeTexture);
    }

    protected override void initJointMatricesBuffer(LogicalDevice device, LoaderNode[] nodes)
    {
        //FIXME: hardcoded skin is used
        auto skin = &content.skins[0];
        skin.fromSkinRootNodeTranslations.length = nodes.length;

        foreach(i, ref node; nodes)
            if(node.skinIdx == 0)
            {
                skin.skinRootNodeIdx = cast(int)i;
                break;
            }

        version(assert)
            jointMatricesUniformBuf = device.create!ReadableTransferBuffer(Matrix4x4f.sizeof * skin.nodesIndices.length, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        else
            jointMatricesUniformBuf = device.create!TransferBuffer(Matrix4x4f.sizeof * skin.nodesIndices.length, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);

        assert(jointMatricesUniformBuf.length > 0);
    }

    protected override void setupNodeTransFromRoot(Node node, size_t idx)
    {
        //FIXME
        node.transFromRoot = &content.skins[0].fromSkinRootNodeTranslations[idx];
    }

    protected override void refreshSkinMatrices(VkCommandBuffer buf)
    {
        //FIXME: recalc skin for each mesh
        recalcSkin();
        jointMatricesUniformBuf.recordUpload(buf);
    }

    private void recalcSkin()
    {
        assert(content.skins.length > 0);
        assert(jointMatricesUniformBuf.length > 0);

        //FIXME: hardcoded skin is used
        const skin = content.skins[0];

        jointMatricesUniformBuf.cpuBuf[0 .. $] = skin.calculateJointMatrices();
    }
}

/// Uses GPU to calculate skin joints
class SkinnedGlTF_skinJointsGPU : SkinnedGlTF
{
    package SkinMatrices skinMatrices;

    package this(
        ref GltfPipelines pipelines,
        DescriptorAllocator allocator,
        MaterialBuffer materialBuffer,
        LogicalDevice device,
        GltfContent cont,
        LoaderNode[] nodes,
        LoaderNode rootSceneNode,
        Texture fakeTexture,
    )
    {
        super(pipelines, allocator, materialBuffer, device, cont, nodes, rootSceneNode, fakeTexture);
    }

    protected override void initJointMatricesBuffer(LogicalDevice device, LoaderNode[] nodes)
    {
        super.initJointMatricesBuffer(device, nodes);

        //FIXME: hardcoded skin is used
        auto skin = &content.skins[0];

        Matrix4x4f[] invBindArr;
        invBindArr.length = skin.inverseBindMatrices.length;
        foreach(i; 0 .. invBindArr.length)
            invBindArr[i] = skin.inverseBindMatrices[i];

        skinMatrices = new SkinMatrices(
            device,
            cast(uint) nodes.length,
            skin.nodesIndices,
            invBindArr,
            jointMatricesUniformBuf.gpuBuffer,
            jointMatricesUniformBuf.length,
        );
    }

    protected override void refreshSkinMatrices(VkCommandBuffer buf)
    {
        auto skin = &content.skins[0];

        Matrix4x4f skinRootInverse = Matrix4x4f.identity;
        if(skin.skinRootNodeIdx >= 0)
            skinRootInverse = skin.fromSkinRootNodeTranslations[skin.skinRootNodeIdx].inverse;

        skinMatrices.setTransFromRoot(skin.fromSkinRootNodeTranslations);
        skinMatrices.run(buf, skinRootInverse);
    }

    protected override void uploadSkinMatricesStatic(scope VkCommandBuffer commandBuffer)
    {
        if(skinMatrices)
            skinMatrices.recordStatic(commandBuffer);
    }

    /// Debug-only: downloads GPU-computed joint matrices and compares them against the CPU path.
    /// Must be called after submitting the command buffer that records `refreshBuffers`.
    version(assert)
    void debugVerifySkinJoints(LogicalDevice device, CommandPool commandPool, scope ref VkCommandBuffer commandBuffer)
    {
        jointMatricesUniformBuf.downloadImmediate(commandPool, commandBuffer);

        auto gpuData = cast(const(float)[]) jointMatricesUniformBuf.cpuBuf;
        auto cpuData = cast(const(float)[]) content.skins[0].calculateJointMatrices();

        assert(gpuData.length == cpuData.length);

        import std.math: abs;
        import std.algorithm: max;

        enum maxAllowedError = 1e-4;
        foreach(i; 0 .. gpuData.length)
        {
            const err = abs(gpuData[i] - cpuData[i]);
            assert(err < maxAllowedError, "joint matrix error " ~ err.to!string ~ " at " ~ i.to!string);
        }
    }
}

///
alias Vector4us = Vector!(ushort, 4);
