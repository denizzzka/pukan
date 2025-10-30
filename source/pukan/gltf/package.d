module pukan.gltf;

import dlib.math;
public import pukan.gltf.loader: loadGlTF2;
public import pukan.gltf.factory: GltfFactory;
import pukan.gltf.loader;
import pukan.gltf.mesh: MeshClass = Mesh, IndicesBuf;
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
    private Texture fakeTexture;
    private GltfContent content;
    alias this = content;

    private VkDescriptorImageInfo[] texturesDescrInfos;
    private GraphicsPipelineCfg* pipeline;

    private MeshClass[] meshes;
    private VkDescriptorSet[] meshesDescriptorSets;

    // TODO: create GlTF class which uses LoaderNode[] as base for internal tree for faster loading
    // The downside of this is that such GlTF characters will not be able to pick up objects in their hands and so like.
    package this(ref GraphicsPipelineCfg pipeline, PoolAndLayoutInfo poolAndLayout, LogicalDevice device, GltfContent cont, LoaderNode[] nodes, LoaderNode rootSceneNode)
    {
        this.pipeline = &pipeline;
        content = cont;
        meshesDescriptorSets = device.allocateDescriptorSets(poolAndLayout, cast(uint) content.meshes.length);

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
                fakeTexture = createFakeTexture1x1(device);

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
            m.calcAABB(r);

        return r;
    }

    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        foreach(m; meshes)
        {
            m.indicesBuffer.buffer.uploadImmediate(commandPool, commandBuffer);
            m.verticesBuffer.uploadImmediate(commandPool, commandBuffer);

            if(m.texCoordsBuf)
                m.texCoordsBuf.uploadImmediate(commandPool, commandBuffer);
        }
    }

    private void setUpEachNode(ref Node node, LogicalDevice device)
    {
        // Node without mesh attached
        if(node.meshIdx < 0) return;

        const mesh = &content.meshes[node.meshIdx];
        assert(mesh.primitives.length == 1, "FIXME: only one mesh primitive supported for now");

        node.mesh = new MeshClass(device, mesh.name, meshesDescriptorSets[node.meshIdx], textures.length > 0);
        meshes ~= node.mesh;

        const primitive = &mesh.primitives[0];
        enforce(primitive.indicesAccessorIdx != -1, "non-indexed geometry isn't supported");

        {
            auto indices = accessors[ primitive.indicesAccessorIdx ];

            debug enforce(indices.type == "SCALAR", indices.type.to!string);

            const indicesAccessor = content.getAccess(indices);
            node.mesh.indicesBuffer = IndicesBuf(device, indices.componentType, indices.count);

            if(node.mesh.indicesBuffer.indexType == VK_INDEX_TYPE_UINT16)
            {
                auto indicesRange = content.rangify!ushort(indicesAccessor);
                auto dstRange = cast(indicesRange.Elem[]) node.mesh.indicesBuffer.buffer.cpuBuf;
                indicesRange.copy(dstRange);
            }
            else if(node.mesh.indicesBuffer.indexType == VK_INDEX_TYPE_UINT32)
            {
                auto indicesRange = content.rangify!uint(indicesAccessor);
                auto dstRange = cast(indicesRange.Elem[]) node.mesh.indicesBuffer.buffer.cpuBuf;
                indicesRange.copy(dstRange);
            }
            else
                assert(0);
        }

        {
            const vertIdx = primitive.attributes["POSITION"].get!ushort;
            auto vertices = &accessors[vertIdx];

            enforce(vertices.count > 0);
            debug assert(vertices.type == "VEC3");
            enforce(vertices.componentType == ComponentType.FLOAT);

            import dlib.math: Vector3f;
            static assert(Vector3f.sizeof == float.sizeof * 3);

            auto verticesAccessor = content.getAccess(*vertices);
            auto range = content.rangify!Vector3f(verticesAccessor);
            node.mesh.verticesBuffer = device.create!TransferBuffer(Vector3f.sizeof * verticesAccessor.count, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            range.copy(cast(Vector3f[]) node.mesh.verticesBuffer.cpuBuf[0 .. $]);
        }

        enforce(!("TEXCOORD_1" in primitive.attributes), "not supported");

        BufAccess texCoordsAccessor;

        if(content.textures.length)
        {
            const idx = primitive.attributes["TEXCOORD_0"].get!ushort;
            auto texCoords = &accessors[idx];

            enforce(texCoords.count > 0);
            debug assert(texCoords.type == "VEC2");
            debug assert(texCoords.componentType == ComponentType.FLOAT);

            texCoordsAccessor = content.getAccess(*texCoords);
            auto ta = &texCoordsAccessor;

            auto textCoordsRange = content.rangify!Vector2f(texCoordsAccessor);

            node.mesh.texCoordsBuf = device.create!TransferBuffer(Vector2f.sizeof * texCoords.count, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);

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

                    textCoordsRange
                        .map!((Vector2f e) => (e - min) / range)
                        .copy(cast(Vector2f[]) node.mesh.texCoordsBuf.cpuBuf[0 .. $]);
                }
            }

            if(!textCoordsRange.empty)
                node.mesh.texCoordsBuf.cpuBuf[0 .. $] = cast(ubyte[]) textCoordsRange.array;
        }

        // Fake texture or real one provided just to stub shader input
        node.mesh.textureDescrImageInfo = &texturesDescrInfos[0];
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

        if(node.mesh && node.mesh.indicesBuffer.count)
        {
            vkCmdPushConstants(buf, pipeline.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, cast(uint) trans.sizeof, cast(void*) &trans);

            node.mesh.drawingBufferFilling(buf, trans);
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
