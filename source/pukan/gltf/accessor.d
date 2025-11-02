module pukan.gltf.accessor;

import pukan.vulkan.bindings;
import pukan.vulkan;
import std.exception: enforce;

class BufferPieceOnGPU
{
    TransferBuffer buffer;

    //TODO: add flag if CPU buf is not needed after uploading
    void uploadImmediate(scope CommandPool commandPool, scope VkCommandBuffer commandBuffer)
    {
        buffer.uploadImmediate(commandPool, commandBuffer);
    }
}

struct BufAccess
{
    ptrdiff_t viewIdx = -1;
    uint offset;
    ubyte stride;
    uint count;
}

package struct AccessRange(T, bool isOutput)
{
    private const void[] buf;
    const BufAccess accessor;
    private const uint bufEnd;
    private uint currByte;
    private uint currStep;

    alias Elem = T;

    package this(in void[] b, in BufAccess a)
    {
        buf = b;

        BufAccess tmp = a;
        if(tmp.stride == 0)
        {
            // tightly packed data
            tmp.stride = T.sizeof;
        }

        accessor = tmp;
        currByte = accessor.offset;
        bufEnd = cast(uint) buf.length;

        enforce(accessor.stride >= T.sizeof);

        assert(!empty);
    }

    void popFront()
    {
        enforce(currByte <= bufEnd - T.sizeof);
        enforce(!empty);

        currStep++;
        currByte += accessor.stride;
    }

    uint length() const => accessor.count;
    bool empty() const => currStep >= length;

    version(BigEndian)
    static assert(false, "big endian not implemented");

    private T* frontPtr() inout
    {
        return cast(T*) cast(void*) &buf[currByte];
    }

    static if(!isOutput)
    ref T front() const => *frontPtr();

    static if(isOutput)
    void put(ref T val)
    {
        *frontPtr = val;
        popFront;
    }
}
