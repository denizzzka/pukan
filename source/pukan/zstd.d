module pukan.zstd;

import pukan.zstd_bindings;

/// Decompresses one Zstandard frame into an exact-size buffer
bool decompressZstd(const(ubyte)[] source, ubyte[] destination) @nogc nothrow
{
    const result = ZSTD_decompress(destination.ptr, destination.length, source.ptr, source.length);
    return !ZSTD_isError(result) && result == destination.length;
}
