module pukan.vulkan.pipeline_cache;

import pukan.exceptions: PukanException;
import std.conv: to;
import std.exception: enforce;
import std.path: buildPath, baseName, extension, stripExtension;
import std.uuid: UUID;

/// Layout of the container around a driver pipeline cache blob
enum pipelineCacheFormatVersion = 1;

/**
    Fixed part of every cache file, stored as raw bytes.

    The magic and the format version come first, so a layout change is
    recognized before any field whose meaning depends on it is read.
*/
align(1) struct PipelineCacheHeader
{
    enum string magicBytes = "VPUKANPC1";

    char[magicBytes.length] magic;
    uint formatVersion;
    ubyte[16] pipelineCacheUUID;
    ulong payloadLength;

    static PipelineCacheHeader create(UUID pipelineCacheUUID, ulong payloadLength)
    {
        PipelineCacheHeader header;
        header.magic[] = magicBytes[];
        header.formatVersion = pipelineCacheFormatVersion;
        header.pipelineCacheUUID = pipelineCacheUUID.data;
        header.payloadLength = payloadLength;

        return header;
    }
}

/// Thrown when a cache record does not match this device or layout
class PipelineCacheLoadException: PukanException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure @safe
    {
        super(msg, file, line, nextInChain);
    }
}

/// Keeps the driver cache blob of every pipeline variant
abstract class PipelineCacheStore
{
    private UUID pipelineCacheUUID;

    this(UUID pipelineCacheUUID)
    {
        this.pipelineCacheUUID = pipelineCacheUUID;
    }

    /// Returns the blob of a variant, null when the store holds no record
    ubyte[] load(string identity)
    {
        const bytes = readRecord(identity);

        if(bytes is null)
            return null;

        enforce!PipelineCacheLoadException(
            bytes.length >= PipelineCacheHeader.sizeof,
            message(identity, "the header is truncated"));

        PipelineCacheHeader header;
        (cast(ubyte*) &header)[0 .. PipelineCacheHeader.sizeof] = bytes[0 .. PipelineCacheHeader.sizeof];

        enforce!PipelineCacheLoadException(
            header.magic[] == PipelineCacheHeader.magicBytes[],
            message(identity, "the magic does not match"));

        enforce!PipelineCacheLoadException(
            header.formatVersion == pipelineCacheFormatVersion,
            message(identity, "the format version changed"));

        enforce!PipelineCacheLoadException(
            header.pipelineCacheUUID[] == pipelineCacheUUID.data[],
            message(identity, "the pipeline cache uuid of the device changed"));

        enforce!PipelineCacheLoadException(
            header.payloadLength == bytes.length - PipelineCacheHeader.sizeof,
            message(identity, "the payload length does not match the file size"));

        return bytes[PipelineCacheHeader.sizeof .. $].dup;
    }

    /// Replaces the record of a variant with a driver blob
    void save(string identity, const(ubyte)[] payload)
    {
        const header = PipelineCacheHeader.create(pipelineCacheUUID, payload.length);

        ubyte[] record;
        record.length = PipelineCacheHeader.sizeof + payload.length;
        record[0 .. PipelineCacheHeader.sizeof] = (cast(const ubyte*) &header)[0 .. PipelineCacheHeader.sizeof];
        record[PipelineCacheHeader.sizeof .. $] = payload;

        writeRecord(identity, record);
    }

    /// Drops the record of a variant, if any
    void invalidate(string identity)
    {
        removeRecord(identity);
    }

    /// Identities the store holds, for progress reporting
    abstract string[] manifest() const;

    protected:
    /// Reads the whole record, null when there is none
    abstract ubyte[] readRecord(string identity);

    /// Writes the whole record, replacing any previous one
    abstract void writeRecord(string identity, const(ubyte)[] record);

    abstract void removeRecord(string identity);

    private static string message(string identity, string reason)
    {
        return "pipeline cache record " ~ identity ~ ": " ~ reason;
    }
}

/// Writes cache files under the user's cache directory
final class FilePipelineCacheStore: PipelineCacheStore
{
    private string directory;

    this(string directory, UUID pipelineCacheUUID)
    in(directory.length > 0)
    {
        super(pipelineCacheUUID);

        this.directory = directory;
    }

    /// Per-user cache directory, null when the environment names none
    static string defaultDirectory(
        uint formatVersion = pipelineCacheFormatVersion,
    )
    {
        import std.process: environment;

        string base;

        version(Windows)
            base = environment.get("LOCALAPPDATA");
        else
        {
            base = environment.get("XDG_CACHE_HOME");

            if(base.length == 0)
            {
                const home = environment.get("HOME");

                if(home.length == 0)
                    return null;

                base = buildPath(home, ".cache");
            }
        }

        if(base.length == 0)
            return null;

        return buildPath(base, "pukan", "pipelines-v" ~ formatVersion.to!string);
    }

    override string[] manifest() const
    {
        import std.algorithm: filter, map, sort;
        import std.array: array;
        import std.file: SpanMode, dirEntries, exists, isFile;

        if(!directory.exists)
            return null;

        auto identities = directory.dirEntries(SpanMode.shallow)
            .filter!(entry => entry.isFile && entry.name.extension == ".pipelinecache")
            .map!(entry => entry.name.baseName.stripExtension)
            .array;

        identities.sort;

        return identities;
    }

    protected:
    override ubyte[] readRecord(string identity)
    {
        import std.file: exists, read;

        const path = filePath(identity);

        if(!path.exists)
            return null;

        return cast(ubyte[]) read(path);
    }

    override void writeRecord(string identity, const(ubyte)[] record)
    {
        import std.file: exists, mkdirRecurse, rename, write;

        if(!directory.exists)
            directory.mkdirRecurse();

        // Rename a temporary file so a crash never leaves half a record
        const path = filePath(identity);
        const tmp = path ~ ".tmp";

        write(tmp, record);
        rename(tmp, path);
    }

    override void removeRecord(string identity)
    {
        import std.file: exists, remove;

        const path = filePath(identity);

        if(path.exists)
            path.remove();
    }

    private string filePath(string identity) const
    {
        return buildPath(directory, identity ~ ".pipelinecache");
    }
}
