module pukan.gltf;

import dlib.math;
public import pukan.gltf.loader: loadGlTF2;
public import pukan.gltf.factory: GltfFactory;
import pukan.gltf.loader;
import pukan.gltf.mesh: MeshClass = Mesh, IndicesBuf, JustColoredMesh, TexturedMesh;
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

    // TODO: create GlTF class which uses LoaderNode[] as base for internal tree for faster loading
    // The downside of this is that such GlTF characters will not be able to pick up objects in their hands and so like.
    package this(ref GraphicsPipelineCfg pipeline, PoolAndLayoutInfo poolAndLayout, LogicalDevice device, GltfContent cont, LoaderNode[] nodes, LoaderNode rootSceneNode, Texture fakeTexture)
    {
        this.pipeline = &pipeline;
        content = cont;
        meshesDescriptorSets = device.allocateDescriptorSets(poolAndLayout, cast(uint) content.meshes.length);

        gpuBuffs.length = content.bufferViews.length;

        {
            Node createNodeHier(ref LoaderNode ln)
            {
                auto nn = new Node(ln.payload);

                foreach(idx; ln.childrenNodeIndices)
                {
                    auto c = createNodeHier(nodes[idx]);
                    nn.addChildNode(c);
                }

                return nn;
            }

            this.rootSceneNode = createNodeHier(rootSceneNode);
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

        BufAccess verticesAccessor;
        //TODO: remove
        TransferBuffer verticesBuffer;

        {
            const vertIdx = primitive.attributes["POSITION"].get!ushort;
            auto vertices = &accessors[vertIdx];

            enforce(vertices.count > 0);
            debug assert(vertices.type == "VEC3");
            enforce(vertices.componentType == ComponentType.FLOAT);

            import dlib.math: Vector3f;
            static assert(Vector3f.sizeof == float.sizeof * 3);

            verticesAccessor = content.getAccess(*vertices);

            createGpuBufIfNeed(device, verticesAccessor, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

            auto verticesRange = content.rangify!(typeof(ShaderVertex.pos))(verticesAccessor);

            verticesBuffer = device.create!TransferBuffer(Vector3f.sizeof * verticesAccessor.count, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

            verticesRange
                .copy(cast(Vector3f[]) verticesBuffer.cpuBuf[0 .. $]);
        }

        uint elemCount;
        IndicesBuf indicesBuffer;

        // If indexed mesh:
        if(primitive.indicesAccessorIdx >= 0)
        {
            auto indices = accessors[ primitive.indicesAccessorIdx ];

            debug enforce(indices.type == "SCALAR", indices.type.to!string);

            const indicesAccessor = content.getAccess(indices);
            indicesBuffer = IndicesBuf(device, indices.componentType, indices.count);
            elemCount = indices.count;

            if(indicesBuffer.indexType == VK_INDEX_TYPE_UINT16)
            {
                auto indicesRange = content.rangify!ushort(indicesAccessor);
                auto dstRange = cast(indicesRange.Elem[]) indicesBuffer.buffer.cpuBuf;
                indicesRange.copy(dstRange);
            }
            else if(indicesBuffer.indexType == VK_INDEX_TYPE_UINT32)
            {
                auto indicesRange = content.rangify!uint(indicesAccessor);
                auto dstRange = cast(indicesRange.Elem[]) indicesBuffer.buffer.cpuBuf;
                indicesRange.copy(dstRange);
            }
            else
                assert(0);
        }
        else
        {
            // Non-indixed meshes:
            elemCount = verticesAccessor.count;
        }

        enforce(!("TEXCOORD_1" in primitive.attributes), "not supported");

        BufAccess texCoordsAccessor;

        if(!content.textures.length)
            node.mesh = new JustColoredMesh(device, mesh.name, verticesAccessor, indicesBuffer, meshesDescriptorSets[node.meshIdx], texturesDescrInfos[0] /* fake texture, always available */);
        else
        {
            const idx = primitive.attributes["TEXCOORD_0"].get!ushort;
            auto texCoords = &accessors[idx];

            enforce(texCoords.count > 0);
            debug assert(texCoords.type == "VEC2");
            debug assert(texCoords.componentType == ComponentType.FLOAT);

            texCoordsAccessor = content.getAccess(*texCoords);
            auto ta = &texCoordsAccessor;

            auto textCoordsRange = content.rangify!Vector2f(texCoordsAccessor);

            // Need to normalize coordinates?
            if(texCoords.min_max != Json.emptyObject)
            {
                const min = Vector2f(texCoords.min_max["min"].deserializeJson!(float[2]));
                const max = Vector2f(texCoords.min_max["max"].deserializeJson!(float[2]));

                if(!(min == Vector2f(0, 0) && max == Vector2f(1, 1)))
                {
                    const range = max - min;

                    version(BigEndian)
                        static assert(false, "big endian arch isn't supported");

                    auto texOutput = content.rangify!(Vector2f, true)(texCoordsAccessor);

                    textCoordsRange
                        .map!((Vector2f e) => (e - min) / range)
                        .copy(texOutput);
                }
            }

            createGpuBufIfNeed(device, texCoordsAccessor, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

            {
                auto m = new TexturedMesh(device, mesh.name, verticesAccessor, indicesBuffer, texCoordsAccessor, meshesDescriptorSets[node.meshIdx]);
                //TODO: only one first texture for everything is used, need to implement "materials":
                m.textureDescrImageInfo = &texturesDescrInfos[0];
                node.mesh = m;
            }
        }

        //TODO: move to ctor
        node.mesh.elemCount = elemCount;

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
        // To avoid mirroring if loaded OpenGL mesh into Vulkan
        trans *= Vector3f(-1, -1, -1).scaleMatrix;

        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);

        vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipelineLayout, 0, cast(uint) meshesDescriptorSets.length, meshesDescriptorSets.ptr, 0, null);

        drawingBufferFillingRecursive(buf, trans, rootSceneNode);
    }

    void drawingBufferFillingRecursive(VkCommandBuffer buf, Matrix4x4f trans, Node node)
    {
        import std.math;

        assert(!node.trans[0].isNaN);

        trans *= node.trans;

        if(node.mesh && node.mesh.elemCount)
        {
            vkCmdPushConstants(buf, pipeline.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, cast(uint) trans.sizeof, cast(void*) &trans);

            node.mesh.drawingBufferFilling(gpuBuffs, buf, trans);
        }

        foreach(c; node.children)
            drawingBufferFillingRecursive(buf, trans, cast(Node) c);
    }
}

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
