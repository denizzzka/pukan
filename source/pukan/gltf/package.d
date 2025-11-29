module pukan.gltf;

import dlib.math;
public import pukan.gltf.loader: loadGlTF2;
public import pukan.gltf.factory: GltfFactory;
import pukan.gltf.accessor;
import pukan.gltf.animation: AnimationSupport;
import pukan.gltf.loader;
import pukan.gltf.mesh: MeshClass = Mesh, IndicesDescr, JustColoredMesh, TexturedMesh, UploadedVertices;
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
    private Node rootSceneNode;
    private Trans rootSceneNodeTrans;

    private GltfContent content;
    alias this = content;

    private BufferPieceOnGPU[] gpuBuffs;
    private VkDescriptorImageInfo[] texturesDescrInfos;
    private GraphicsPipelineCfg* pipeline;

    private MeshClass[] meshes;

    package TransferBuffer jointMatricesUniformBuf;
    private VkDescriptorBufferInfo jointsUboInfo;

    private Trans[] baseNodeTranslations;
    private AnimationSupport animation;

    // TODO: create GlTF class which uses LoaderNode[] as base for internal tree for faster loading
    // The downside of this is that such GlTF characters will not be able to pick up objects in their hands and so like.
    package this(ref GraphicsPipelineCfg pipeline, PoolAndLayoutInfo poolAndLayout, LogicalDevice device, GltfContent cont, LoaderNode[] nodes, LoaderNode rootSceneNode, Texture fakeTexture)
    {
        this.pipeline = &pipeline;
        content = cont;

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
            if(content.skins.length > 0)
            {
                //FIXME: hardcoded skin is used
                auto skin = &content.skins[0];
                skin.fromSkinRootNodeTranslations.length = nodes.length;

                jointMatricesUniformBuf = device.create!TransferBuffer(Matrix4x4f.sizeof * skin.nodesIndices.length, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
                assert(jointMatricesUniformBuf.length > 0);
            }
            else
            {
                //TODO: remove this fake buffer
                Matrix4x4f[] identityBuf;
                identityBuf.length = nodes.length;
                identityBuf[0..$] = Matrix4x4f.identity;

                jointMatricesUniformBuf = device.create!TransferBuffer(Matrix4x4f.sizeof * identityBuf.length, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
                jointMatricesUniformBuf.cpuBuf[0 .. $] = identityBuf;
            }

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

                    //FIXME
                    if(content.skins.length > 0)
                        c.transFromRoot = &content.skins[0].fromSkinRootNodeTranslations[idx];

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
                texturesDescrInfos[0] = VkDescriptorImageInfo(
                    imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    imageView: fakeTexture.imageView,
                    sampler: fakeTexture.sampler,
                );
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
            setUpEachNode(node, device, poolAndLayout);
        });

        if(content.skins.length == 0)
        {
            // Adds fake buffer for joints and weights when skins not used to allow skinned vertices shader work as usual
            gpuBuffs ~= new BufferPieceOnGPU;
            gpuBuffs ~= new BufferPieceOnGPU;

            // joints (zeroed)
            gpuBuffs[$-2].buffer = new TransferBuffer(device, Vector4us.sizeof * nodes.length, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            // weights
            gpuBuffs[$-1].buffer = new TransferBuffer(device, Vector4f.sizeof * nodes.length, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

            auto weights = new Vector4f[nodes.length];
            weights[0..$] = Vector4f(1, 1, 1, 1);

            gpuBuffs[$-1].buffer.cpuBuf[0 .. $] = weights;
        }

        // For skin support:
        this.rootSceneNode.refreshTransFromRootValues;
    }

    private void recalcSkin()
    {
        assert(content.skins.length > 0);
        assert(jointMatricesUniformBuf.length > 0);

        //FIXME: hardcoded skin is used
        const skin = content.skins[0];

        jointMatricesUniformBuf.cpuBuf[0 .. $] = skin.calculateJointMatrices();
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
        foreach(ref buf; gpuBuffs)
            if(buf)
                buf.uploadImmediate(commandPool, commandBuffer);

        foreach(ref mesh; meshes)
            mesh.updateDescriptorSetsAndUniformBuffers(device);

        foreach(m; meshes)
            m.uploadImmediate(commandPool, commandBuffer);
    }

    private void setUpEachNode(ref Node node, LogicalDevice device, ref PoolAndLayoutInfo poolAndLayout)
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

            createGpuBufIfNeed(device, uplVert.vertices, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        }

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

        if(!content.textures.length)
            node.mesh = new JustColoredMesh(device, mesh.name, uplVert, poolAndLayout, texturesDescrInfos[0] /* fake texture, always available */, jointsUboInfo);
        else
        {
            const idx = primitive.attributes["TEXCOORD_0"].get!ushort;
            auto texCoords = &accessors[idx];

            enforce(texCoords.count > 0);
            debug assert(texCoords.type == "VEC2");
            debug assert(texCoords.componentType == ComponentType.FLOAT);

            uplVert.texCoords = content.getAccess!(Type.VEC2, Vector2f)(*texCoords);
            auto ta = &uplVert.texCoords;

            //~ auto textCoordsRange = content.rangify!Vector2f(uplVert.texCoords);

            // Need to normalize coordinates?
            //~ if(texCoords.min_max != Json.emptyObject)
            version(none)
            {
                texCoords.min_max.writeln;

                const min = Vector2f(texCoords.min_max["min"].deserializeJson!(float[2]));
                const max = Vector2f(texCoords.min_max["max"].deserializeJson!(float[2]));

                if(!(min == Vector2f(0, 0) && max == Vector2f(1, 1)))
                {
                    const range = max - min;

                    auto texOutput = content.rangify!(Vector2f, true)(texCoordsAccessor);

                    textCoordsRange
                        .map!((Vector2f e) => (e - min) / range)
                        .copy(texOutput);
                }
            }

            createGpuBufIfNeed(device, uplVert.texCoords, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

            {
                auto m = new TexturedMesh(device, mesh.name, uplVert, poolAndLayout, jointsUboInfo);
                //TODO: only one first texture for everything is used, need to implement "materials":
                m.textureDescrImageInfo = &texturesDescrInfos[0];
                node.mesh = m;
            }
        }

        meshes ~= node.mesh;
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

        //FIXME: recalc skin for each mesh
        if(content.skins.length)
            recalcSkin();

        jointMatricesUniformBuf.recordUpload(buf);

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

        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);

        drawingBufferFillingRecursive(buf, trans, rootSceneNode);
    }

    //TODO: not need to call this recursive - just call it in row and use fromSkinRootNodeTranslations to get coords
    private void drawingBufferFillingRecursive(VkCommandBuffer buf, Matrix4x4f trans, Node node)
    {
        import std.math;

        assert(node.trans !is null);

        trans *= node.trans.calcMatrix;

        if(node.mesh)
        {
            vkCmdPushConstants(buf, pipeline.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, cast(uint) trans.sizeof, cast(void*) &trans);

            node.mesh.drawingBufferFilling(gpuBuffs, pipeline, buf);
        }

        foreach(c; node.children)
            drawingBufferFillingRecursive(buf, trans, cast(Node) c);
    }
}

///
alias Vector4us = Vector!(ushort, 4);

//TODO: use as mandatory vertex shader creation argument?
//TODO: move to C header and use from GLSL code too
struct ShaderVertex
{
    Vector3f pos;
    Vector2f texCoord;

    //TODO: convert to enum?
    static auto getBindingDescriptions()
    {
        return [
            VkVertexInputBindingDescription(
                binding: 0,
                stride: pos.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
            VkVertexInputBindingDescription(
                binding: 1,
                stride: texCoord.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
            // joint indices:
            VkVertexInputBindingDescription(
                binding: 2,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
            // weights:
            VkVertexInputBindingDescription(
                binding: 3,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
        ];
    }

    //TODO: convert to enum?
    static auto getAttributeDescriptions()
    {
        return [
            // position:
            VkVertexInputAttributeDescription(
                binding: 0,
                location: 0,
                format: VK_FORMAT_R32G32B32_SFLOAT,
                //~ offset: pos.offsetof,
            ),
            // textureCoord:
            VkVertexInputAttributeDescription(
                binding: 1,
                location: 1,
                format: VK_FORMAT_R32G32_SFLOAT,
                //~ offset: texCoord.offsetof,
            ),
            // joint indices:
            VkVertexInputAttributeDescription(
                binding: 2,
                location: 2,
                format: VK_FORMAT_R16G16B16A16_UINT,
            ),
            // weights:
            VkVertexInputAttributeDescription(
                binding: 3,
                location: 3,
                format: VK_FORMAT_R32G32B32A32_SFLOAT,
            ),
        ];
    }
};
