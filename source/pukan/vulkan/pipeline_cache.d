module pukan.vulkan.pipeline_cache;

import pukan.exceptions: PukanException;
import std.conv: to;
import std.digest.sha: SHA256, toHexString;
import std.exception: enforce;
import std.path: buildPath, baseName, extension, stripExtension;
import std.uuid: UUID;

/// Layout of the container around a driver pipeline cache blob
enum pipelineCacheFormatVersion = 1;


/// Identifies a pipeline variant by a digest of the state that defines it
struct PipelineVariantKey
{
    ubyte[32] digest;

    string toString() const
    {
        return cast(string) toHexString(digest.dup);
    }

    int opCmp(ref const PipelineVariantKey rhs) const nothrow @safe
    {
        return digest[] < rhs.digest[] ? -1 : digest[] > rhs.digest[] ? 1 : 0;
    }

    size_t toHash() const nothrow @safe
    {
        return hashOf(digest);
    }
}

/// Feeds the creation state of one variant into a `PipelineVariantKey`
struct PipelineVariantKeyBuilder
{
    private SHA256 hash;

    void add(T)(in T value)
    {
        hash.put((cast(const ubyte*) &value)[0 .. T.sizeof]);
    }

    void addString(string value)
    {
        add(value.length);
        hash.put(cast(const ubyte[]) value);
    }

    void addArray(T)(const(T)[] values)
    {
        add(values.length);

        foreach(ref value; values)
            add(value);
    }

    PipelineVariantKey finish()
    {
        PipelineVariantKey key;
        key.digest = hash.finish;

        return key;
    }
}

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
    ubyte[] load(PipelineVariantKey identity)
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
    void save(PipelineVariantKey identity, const(ubyte)[] payload)
    {
        const header = PipelineCacheHeader.create(pipelineCacheUUID, payload.length);

        ubyte[] record;
        record.length = PipelineCacheHeader.sizeof + payload.length;
        record[0 .. PipelineCacheHeader.sizeof] = (cast(const ubyte*) &header)[0 .. PipelineCacheHeader.sizeof];
        record[PipelineCacheHeader.sizeof .. $] = payload;

        writeRecord(identity, record);
    }

    /// Drops the record of a variant, if any
    void invalidate(PipelineVariantKey identity)
    {
        removeRecord(identity);
    }

    /// Variants the store holds, for progress reporting
    abstract PipelineVariantKey[] manifest() const;

    /// Drops the least recently used records until the store fits its bounds
    void trim()
    {
    }

    protected:
    /// Reads the whole record, null when there is none
    abstract ubyte[] readRecord(PipelineVariantKey identity);

    /// Writes the whole record, replacing any previous one
    abstract void writeRecord(PipelineVariantKey identity, const(ubyte)[] record);

    abstract void removeRecord(PipelineVariantKey identity);

    private static string message(PipelineVariantKey identity, string reason)
    {
        return "pipeline cache record " ~ identity.toString() ~ ": " ~ reason;
    }
}

/// Writes cache files under the user's cache directory
final class FilePipelineCacheStore: PipelineCacheStore
{
    enum defaultMaxBytes = 64 * 1024 * 1024;
    enum defaultMaxRecords = 4096;

    private string directory;
    private size_t maxBytes;
    private size_t maxRecords;

    this(
        string directory,
        UUID pipelineCacheUUID,
        size_t maxBytes = defaultMaxBytes,
        size_t maxRecords = defaultMaxRecords,
    )
    in(directory.length > 0)
    in(maxBytes > 0)
    in(maxRecords > 0)
    {
        super(pipelineCacheUUID);

        this.directory = directory;
        this.maxBytes = maxBytes;
        this.maxRecords = maxRecords;
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

    override PipelineVariantKey[] manifest() const
    {
        import std.algorithm: filter, map, sort;
        import std.array: array;
        import std.file: SpanMode, dirEntries, exists, isFile;

        if(!directory.exists)
            return null;

        auto keys = directory.dirEntries(SpanMode.shallow)
            .filter!(entry => entry.isFile && entry.name.extension == ".pipelinecache")
            .map!(entry => entry.name.baseName.stripExtension)
            .filter!(name => isKeyName(name))
            .map!(name => parseKey(name))
            .array;

        keys.sort;

        return keys;
    }

    override void trim()
    {
        import std.algorithm: sort;
        import std.datetime: SysTime;
        import std.file: FileException, SpanMode, dirEntries, exists, getSize, isFile, remove, timeLastModified;

        if(!directory.exists)
            return;

        struct Record
        {
            string path;
            SysTime used;
            size_t size;
        }

        Record[] records;

        foreach(entry; directory.dirEntries(SpanMode.shallow))
        {
            if(!entry.isFile || entry.name.extension != ".pipelinecache")
                continue;

            try
                records ~= Record(entry.name, entry.name.timeLastModified, entry.name.getSize);
            catch(FileException)
                continue;
        }

        // The oldest mtime goes first; every run rewrites the variants it uses
        records.sort!((a, b) => a.used < b.used);

        size_t totalBytes;
        foreach(ref record; records)
            totalBytes += record.size;

        size_t evicted;
        size_t remaining = records.length;

        while(evicted < records.length && (totalBytes > maxBytes || remaining > maxRecords))
        {
            totalBytes -= records[evicted].size;
            --remaining;
            ++evicted;
        }

        foreach(ref record; records[0 .. evicted])
        {
            try
                record.path.remove;
            catch(FileException)
            {
            }
        }
    }

    protected:
    override ubyte[] readRecord(PipelineVariantKey identity)
    {
        import std.file: FileException, exists, read;

        const path = filePath(identity);

        if(!path.exists)
            return null;

        // A sweep may remove a record between the check and the read
        try
            return cast(ubyte[]) read(path);
        catch(FileException)
            return null;
    }

    override void writeRecord(PipelineVariantKey identity, const(ubyte)[] record)
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

    override void removeRecord(PipelineVariantKey identity)
    {
        import std.file: exists, remove;

        const path = filePath(identity);

        if(path.exists)
            path.remove();
    }

    private string filePath(PipelineVariantKey identity) const
    {
        return buildPath(directory, identity.toString() ~ ".pipelinecache");
    }

    private static bool isKeyName(string name)
    {
        import std.algorithm: all;
        import std.ascii: isHexDigit;

        return name.length == PipelineVariantKey.digest.length * 2 && name.all!isHexDigit;
    }

    private static PipelineVariantKey parseKey(string name)
    {
        import std.digest: fromHexString;

        PipelineVariantKey key;
        key.digest[] = fromHexString(name);

        return key;
    }
}
