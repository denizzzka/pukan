module pukan.gltf.mesh;

import dlib.math;
public import pukan.gltf.loader: BufAccess;
import pukan.vulkan;
import pukan.vulkan.bindings;

class Mesh
{
    string name;
    /*private*/ BufAccess indicesAccessor;
    /*private*/ ushort indices_count;

    this(string name)
    {
        this.name = name;
    }

    //TODO: buffers seems redundant: accessor can provide this functionality
    void drawingBufferFilling(TransferBuffer[] buffers, VkCommandBuffer buf, in Matrix4x4f trans)
    {
        assert(indices_count);
        assert(indicesAccessor.stride == ushort.sizeof);

        auto indicesBuffer = buffers[indicesAccessor.bufIdx];

        vkCmdBindIndexBuffer(buf, indicesBuffer.gpuBuffer.buf.getVal(), indicesAccessor.offset, VK_INDEX_TYPE_UINT16);
        vkCmdDrawIndexed(buf, indices_count, 1, 0, 0, 0);
    }
}
