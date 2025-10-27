module pukan.gltf;

import dlib.math;
public import pukan.gltf.loader: loadGlTF2;
public import pukan.gltf.factory: GltfFactory;
import pukan.gltf.loader;
import pukan.gltf.mesh: MeshClass = Mesh, IndicesBuf;
import pukan.tree: BaseNode = Node;
import pukan.vulkan.bindings;
import pukan.vulkan;
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

    private TransferBuffer[] buffers;
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

        this.buffers.length = content.buffers.length;
        foreach(i, buf; content.buffers)
        {
            //TODO: usage bits may be set by using introspection of destiny of the buffer
            this.buffers[i] = device.create!TransferBuffer(buf.buf.length, VK_BUFFER_USAGE_INDEX_BUFFER_BIT|VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            //TODO: get rid of this redundant copying:
            this.buffers[i].cpuBuf[0..$] = buf.buf[0 .. $];
        }

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

    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        foreach(ref buf; buffers)
            buf.uploadImmediate(commandPool, commandBuffer);

        foreach(m; meshes)
        {
            m.indicesBuffer.buffer.uploadImmediate(commandPool, commandBuffer);

            if(m.texCoordsBuf)
                m.texCoordsBuf.uploadImmediate(commandPool, commandBuffer);
        }
    }

    private void setUpEachNode(ref Node node, LogicalDevice device)
    {
        // Node without mesh attached
        if(node.meshIdx < 0) return;

        const mesh = &content.meshes[node.meshIdx];
        assert(mesh.primitives.length == 1);

        node.mesh = new MeshClass(device, mesh.name, meshesDescriptorSets[node.meshIdx], textures.length > 0);
        meshes ~= node.mesh;

        const primitive = &mesh.primitives[0];
        enforce(primitive.indicesAccessorIdx != -1, "non-indexed geometry isn't supported");

        auto indices = accessors[ primitive.indicesAccessorIdx ];

        debug enforce(indices.type == "SCALAR", indices.type.to!string);

        const indicesAccessor = content.getAccess(indices);
        node.mesh.indicesBuffer = IndicesBuf(device, indices.componentType, indices.count);

        {
            const vertIdx = primitive.attributes["POSITION"].get!ushort;
            auto vertices = &accessors[vertIdx];

            enforce(vertices.count > 0);
            debug assert(vertices.type == "VEC3");
            debug assert(vertices.componentType == ComponentType.FLOAT);

            import dlib.math: Vector3f;
            static assert(Vector3f.sizeof == float.sizeof * 3);

            node.mesh.verticesAccessor = content.getAccess(*vertices);

            if(node.mesh.verticesAccessor.stride == 0)
                node.mesh.verticesAccessor.stride = Vector3f.sizeof;
        }

        auto verticesRange = content.rangify!Vector3f(node.mesh.verticesAccessor);

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

            if(ta.stride == 0)
                texCoordsAccessor.stride = Vector2f.sizeof;

            enforce(ta.stride >= Vector2f.sizeof, ta.stride.to!string);

            /* TODO:
            Such approach to buffer leads to buffer data duplication.
            But this avoids complicating the shader. In the future,
            it's better to create a shader with a configurable stride
            value
            */
            ubyte[] texCoordsSlice = cast(ubyte[]) buffers[ta.bufIdx]
                .cpuBuf[ta.offset .. ta.offset + ta.stride * texCoords.count];

            enforce(texCoordsSlice.length > 0);
            enforce(texCoordsSlice.length % ta.stride == 0);

            import std.algorithm;
            import std.array;
            import std.range;

            auto fetchedCoords = texCoordsSlice
                .chunks(ta.stride)
                .map!((ubyte[] b){
                    return *cast(Vector2f*) &b[0];
                });

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

                    fetchedCoords
                        .each!((e){
                            e = (e - min) / range;
                        });
                }
            }

            node.mesh.texCoordsBuf = device.create!TransferBuffer(Vector2f.sizeof * texCoords.count, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            node.mesh.texCoordsBuf.cpuBuf[0 .. $] = cast(ubyte[]) fetchedCoords.array;
        }

        // Fill buffers with a format specifically designed for out shaders
        {
            import std.algorithm;
            import std.range;

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


            {
                node.mesh.verticesBuffer = device.create!TransferBuffer(ShaderVertex.sizeof * verticesRange.accessor.count, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
                auto dstRange = cast(ShaderVertex[]) node.mesh.verticesBuffer.cpuBuf[0 .. $];

                if(texCoordsAccessor.bufIdx >= 0)
                {
                    auto texCoordsRange = content.rangify!Vector2f(texCoordsAccessor);

                    zip(verticesRange, texCoordsRange, dstRange)
                        .each!((ref vert, ref tex, ref dst){
                            dst.pos = vert;
                            dst.texCoord = tex;
                        });
                }
                else
                {
                    zip(verticesRange, dstRange)
                        .each!((ref vert, ref dst){
                            dst.pos = vert;
                        });
                }
            }
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
        //~ trans *= Vector3f(-1, -1, -1).scaleMatrix;

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

            node.mesh.drawingBufferFilling(buffers, buf, trans);
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
