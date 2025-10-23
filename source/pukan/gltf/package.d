module pukan.gltf;

import dlib.math;
public import pukan.gltf.loader: loadGlTF2;
public import pukan.gltf.factory: GltfFactory;
import pukan.gltf.loader;
import pukan.tree: BaseNode = Node;
import pukan.vulkan.bindings;
import pukan.vulkan;
import std.conv: to;
import std.exception: enforce;
import vibe.data.json;

alias LoaderNode = pukan.gltf.loader.Node;

class Node : BaseNode
{
    private BufAccess indicesAccessor;
    private ushort indices_count;

    NodePayload payload;
    alias this = payload;

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
    private BufAccess verticesAccessor;
    private TransferBuffer texCoordsBuf;
    private GraphicsPipelineCfg* pipeline;
    private VkDescriptorSet[] descriptorSets;
    private TransferBuffer uniformBuffer;

    static struct UBOContent
    {
        static struct Material
        {
            Vector4i renderType;
            Vector4f baseColorFactor;
        }

        Material material;
    }

    // TODO: create GlTF class which uses LoaderNode[] as base for internal tree for faster loading
    // The downside of this is that such GlTF characters will not be able to pick up objects in their hands and so like.
    package this(ref GraphicsPipelineCfg pipeline, VkDescriptorSet[] ds, LogicalDevice device, GltfContent cont, LoaderNode[] nodes, LoaderNode rootSceneNode)
    {
        this.pipeline = &pipeline;
        descriptorSets = ds;
        content = cont;

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

        // TODO: bad idea to allocate a memory buffer only for one uniform buffer,
        // need to allocate more memory then divide it into pieces
        uniformBuffer = device.create!TransferBuffer(UBOContent.sizeof, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);

        ubo.material.baseColorFactor = Vector4f(0, 1, 1, 1);
        ubo.material.renderType.x = textures.length ? 1 : 0;

        fakeTexture = createFakeTexture1x1(device);
        updateDescriptorSetsAndUniformBuffers(device);
    }

    ~this()
    {
        uniformBuffer.destroy;
    }

    private ref UBOContent ubo()
    {
        return *cast(UBOContent*) uniformBuffer.cpuBuf.ptr;
    }

    void uploadToGPUImmediate(LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        rootSceneNode.traversal((node){
            setUpEachNode(node, device, commandPool, commandBuffer);
        });

        foreach(ref buf; buffers)
            buf.uploadImmediate(commandPool, commandBuffer);

        texCoordsBuf.uploadImmediate(commandPool, commandBuffer);
    }

    private void setUpEachNode(ref Node node, LogicalDevice device, CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        // Node without mesh attached
        if(node.meshIdx < 0) return;

        const mesh = &meshes[node.meshIdx];
        assert(mesh.primitives.length == 1);

        const primitive = &mesh.primitives[0];
        enforce(primitive.indicesAccessorIdx != -1, "non-indexed geometry isn't supported");

        {
            auto indices = accessors[ primitive.indicesAccessorIdx ];

            debug
            {
                import std.conv: to;

                enforce(indices.type == "SCALAR", indices.type.to!string);
                enforce(indices.componentType == ComponentType.UNSIGNED_SHORT, indices.componentType.to!string);
            }

            assert(indices.count > 0);
            node.indices_count = cast(ushort) indices.count;

            node.indicesAccessor = content.getAccess(indices);

            //TODO: unused, remove:
            if(node.indicesAccessor.stride == 0)
                node.indicesAccessor.stride = ushort.sizeof;

            {
                auto bb = buffers[node.indicesAccessor.bufIdx].cpuBuf[node.indicesAccessor.offset .. node.indicesAccessor.offset + node.indices_count * node.indicesAccessor.stride];
                import std.stdio;
                writeln(cast(ushort[]) bb);
            }
        }

        {
            const vertIdx = primitive.attributes["POSITION"].get!ushort;
            auto vertices = &accessors[vertIdx];

            enforce(vertices.count > 0);
            debug assert(vertices.type == "VEC3");
            debug assert(vertices.componentType == ComponentType.FLOAT);

            import dlib.math: Vector3f;
            static assert(Vector3f.sizeof == float.sizeof * 3);

            verticesAccessor = content.getAccess(*vertices);
            if(verticesAccessor.stride == 0)
                verticesAccessor.stride = Vector3f.sizeof;

            {
                auto bb = buffers[verticesAccessor.bufIdx].cpuBuf[verticesAccessor.offset .. verticesAccessor.offset + vertices.count * verticesAccessor.stride];
                import std.stdio;
                writeln(cast(Vector3f[]) bb);
            }
        }

        enforce(!("TEXCOORD_1" in primitive.attributes), "not supported");

        if(content.textures.length)
        {
            const idx = primitive.attributes["TEXCOORD_0"].get!ushort;
            auto texCoords = &accessors[idx];

            enforce(texCoords.count > 0);
            debug assert(texCoords.type == "VEC2");
            debug assert(texCoords.componentType == ComponentType.FLOAT);

            auto texCoordsAccessor = content.getAccess(*texCoords);
            auto ta = &texCoordsAccessor;

            enforce(ta.stride >= Vector2f.sizeof);

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

                //~ if(!(min == Vector2f(0, 0) && max == Vector2f(1, 1)))
                {
                    const range = max - min;

                    version(BigEndian)
                        static assert(false, "big endian arch isn't supported");

                    import std.stdio;
                    writeln("normalize:");

                    fetchedCoords
                        .each!((e){
                            writeln("fro=", e);
                            e = (e - min) / range;
                            writeln("res=", e);
                        });
                }
            }

            texCoordsBuf = device.create!TransferBuffer(Vector2f.sizeof * texCoords.count, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            texCoordsBuf.cpuBuf[0 .. $] = cast(ubyte[]) fetchedCoords.array;
        }
    }

    private void updateDescriptorSetsAndUniformBuffers(LogicalDevice device)
    {
        VkDescriptorBufferInfo bufferInfo = {
            buffer: uniformBuffer.gpuBuffer,
            offset: 0,
            range: UBOContent.sizeof,
        };

        assert(descriptorSets.length == 1);

        {
            import std.conv: to;
            assert(textures.length <= 1, textures.length.to!string);
        }

        VkDescriptorImageInfo imageInfo;

        if(textures.length == 0)
        {
            imageInfo = VkDescriptorImageInfo(
                imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                imageView: fakeTexture.imageView,
                sampler: fakeTexture.sampler,
            );
        }
        else
        {
            imageInfo = VkDescriptorImageInfo(
                imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                imageView: textures[0].imageView,
                sampler: textures[0].sampler,
            );
        }

        VkWriteDescriptorSet[] descriptorWrites = [
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: descriptorSets[0],
                dstBinding: 0,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                pBufferInfo: &bufferInfo,
            ),
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: descriptorSets[0],
                dstBinding: 1,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                pImageInfo: &imageInfo,
            ),
        ];

        device.updateDescriptorSets(descriptorWrites);
    }

    void refreshBuffers(VkCommandBuffer buf)
    {
        uniformBuffer.recordUpload(buf);
    }

    void drawingBufferFilling(VkCommandBuffer buf, Matrix4x4f trans)
    {
        //~ trans *= Vector3f(-1, -1, -1).scaleMatrix;

        vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.graphicsPipeline);

        assert(verticesAccessor.stride);
        auto vertexBuffer = buffers[verticesAccessor.bufIdx];
        assert(vertexBuffer.cpuBuf.length > 5);

        VkBuffer[2] buffers = [
            vertexBuffer.gpuBuffer.buf.getVal(),
            texCoordsBuf
                ? texCoordsBuf.gpuBuffer.buf.getVal()
                : vertexBuffer.gpuBuffer.buf.getVal(), // fake data to fill out texture coords buffer on non-textured objects
        ];
        VkDeviceSize[2] offsets = [verticesAccessor.offset, 0];
        vkCmdBindVertexBuffers(buf, 0, cast(uint) buffers.length, buffers.ptr, offsets.ptr);

        vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipelineLayout, 0, cast(uint) descriptorSets.length, descriptorSets.ptr, 0, null);

        drawingBufferFillingRecursive(buf, trans, rootSceneNode);
    }

    void drawingBufferFillingRecursive(VkCommandBuffer buf, Matrix4x4f trans, Node node)
    {
        import std.math;

        assert(!node.trans[0].isNaN);

        trans *= node.trans;

        if(node.indices_count)
        {
            assert(node.indicesAccessor.stride == ushort.sizeof);
            auto indicesBuffer = buffers[node.indicesAccessor.bufIdx];

            vkCmdPushConstants(buf, pipeline.pipelineLayout, VK_SHADER_STAGE_VERTEX_BIT, 0, cast(uint) trans.sizeof, cast(void*) &trans);
            vkCmdBindIndexBuffer(buf, indicesBuffer.gpuBuffer.buf.getVal(), node.indicesAccessor.offset, VK_INDEX_TYPE_UINT16);
            vkCmdDrawIndexed(buf, node.indices_count, 1, 0, 0, 0);
        }

        foreach(c; node.children)
            drawingBufferFillingRecursive(buf, trans, cast(Node) c);
    }
}

//TODO: use as mandatory vertex shader creation argument?
struct ShaderInputVertex
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
