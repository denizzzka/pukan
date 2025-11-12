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

class Node : BaseNode
{
    NodePayload payload;
    alias this = payload;

    Matrix4x4f* trans;
    package Matrix4x4f skinInverseBind;
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
}

class GlTF : DrawableByVulkan
{
    private Node rootSceneNode;
    private GltfContent content;
    alias this = content;

    private BufferPieceOnGPU[] gpuBuffs;
    private VkDescriptorImageInfo[] texturesDescrInfos;
    private GraphicsPipelineCfg* pipeline;

    private MeshClass[] meshes;
    private VkDescriptorSet[] meshesDescriptorSets;

    package TransferBuffer jointMatricesUniformBuf;

    private AnimationSupport animation;

    // TODO: create GlTF class which uses LoaderNode[] as base for internal tree for faster loading
    // The downside of this is that such GlTF characters will not be able to pick up objects in their hands and so like.
    package this(ref GraphicsPipelineCfg pipeline, PoolAndLayoutInfo poolAndLayout, LogicalDevice device, GltfContent cont, LoaderNode[] nodes, Matrix4x4f[] jointMatrices, LoaderNode rootSceneNode, Texture fakeTexture)
    {
        this.pipeline = &pipeline;
        content = cont;
        meshesDescriptorSets = device.allocateDescriptorSets(poolAndLayout, cast(uint) content.meshes.length);

        jointMatricesUniformBuf = device.create!TransferBuffer(Matrix4x4f.sizeof * jointMatrices.length, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
        jointMatricesUniformBuf.cpuBuf = jointMatrices[0 .. $];

        animation = AnimationSupport(&content, nodes.length);
        gpuBuffs.length = content.bufferViews.length;

        {
            animation.perNodeTranslations[$-1] = rootSceneNode.trans;

            foreach(i, ref node; nodes)
                animation.perNodeTranslations[i] = node.trans;
        }

        {
            Matrix4x4f getSkinInverseBin(uint nodeIdx)
            {
                if(content.skins.length == 0)
                    return Matrix4x4f.identity;

                //TODO: implement skin switching
                const skin = content.skins[0];
                auto invRange = content.rangify!Matrix4x4f(skin.inverseBindMatrices);

                foreach(i, idx; skin.nodesIndices)
                    if(idx == nodeIdx)
                        return invRange[i];

                return Matrix4x4f.identity;
            }

            Node createNodeHier(ref LoaderNode ln)
            {
                auto nn = new Node(ln.payload);

                foreach(idx; ln.childrenNodeIndices)
                {
                    auto c = createNodeHier(nodes[idx]);
                    c.skinInverseBind = getSkinInverseBin(idx);
                    c.trans = &animation.perNodeTranslations[idx];
                    nn.addChildNode(c);
                }

                return nn;
            }

            this.rootSceneNode = createNodeHier(rootSceneNode);
            this.rootSceneNode.skinInverseBind = Matrix4x4f.identity;
            this.rootSceneNode.trans = &animation.perNodeTranslations[$-1];
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
            setUpEachNode(node, device);
        });

        assert(meshesDescriptorSets.length == 1);

        foreach(ref mesh; meshes)
            mesh.updateDescriptorSetsAndUniformBuffers(device);
    }

    string name() const
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

    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        jointMatricesUniformBuf.uploadImmediate(commandPool, commandBuffer);

        foreach(ref buf; gpuBuffs)
            if(buf)
                buf.uploadImmediate(commandPool, commandBuffer);

        foreach(m; meshes)
            m.uploadImmediate(commandPool, commandBuffer);
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

            createGpuBufIfNeed(device, uplVert.vertices, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        }

        if(content.skins.length)
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
            node.mesh = new JustColoredMesh(device, mesh.name, uplVert, meshesDescriptorSets[node.meshIdx], texturesDescrInfos[0] /* fake texture, always available */);
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
                auto m = new TexturedMesh(device, mesh.name, uplVert, meshesDescriptorSets[node.meshIdx]);
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
        foreach(e; meshes)
            e.refreshBuffers(buf);
    }

    void drawingBufferFilling(VkCommandBuffer buf, Matrix4x4f trans)
    {
        if(isAnimated)
        {
            // Update animation
            static float time = 0;
            time += 0.003;

            import std;

            const pose = animation.calculatePose(&animations[0], time);
            //~ writeln("\n\n\n>>>>>>>>>\npose.length=", pose.length);
            //~ writeln("time=", time);
            animation.perNodeTranslations[0 .. $-1] = pose[0 .. $];
            //~ writeln(animation.perNodeTranslations);

            //~ writeln("pose=", pose);
        }

        // To avoid mirroring if loaded OpenGL mesh into Vulkan
        trans *= Vector3f(-1, -1, -1).scaleMatrix;

        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);

        vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipelineLayout, 0, cast(uint) meshesDescriptorSets.length, meshesDescriptorSets.ptr, 0, null);

        drawingBufferFillingRecursive(buf, trans, rootSceneNode);
    }

    void drawingBufferFillingRecursive(VkCommandBuffer buf, Matrix4x4f trans, Node node)
    {
        import std.math;

        assert(node.trans !is null);

        auto localTrans = trans * node.skinInverseBind * *node.trans;

        if(node.mesh)
        {
            vkCmdPushConstants(buf, pipeline.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, cast(uint) localTrans.sizeof, cast(void*) &localTrans);

            node.mesh.drawingBufferFilling(gpuBuffs, buf);
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
        ];
    }

    //TODO: convert to enum?
    static auto getAttributeDescriptions()
    {
        VkVertexInputAttributeDescription[2] ad = [
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
        ];

        return ad;
    }
};
