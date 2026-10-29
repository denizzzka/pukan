module pukan.godot_scene.pck;

import pukan.exceptions: PukanException;
import pukan.godot_scene.paths: normalizeResourcePath;
import std.conv: to;

private enum packMagic = 0x43504447; // "GDPC"
private enum packVersion2 = 2;
private enum packVersion3 = 3;
private enum packVersion4 = 4;
private enum packDirEncrypted = 1 << 0;
private enum packRelFileBase = 1 << 1;
private enum packFileEncrypted = 1 << 0;
private enum packFileRemoval = 1 << 1;
private enum packFileDelta = 1 << 2;

struct PckEntry
{
    string path;
    size_t offset;
    size_t size;
}

/// A Godot PCK archive, v2 to v4, unencrypted
final class PckArchive
{
    private const(ubyte)[] file;
    private PckEntry[string] entries;

    this(string path)
    {
        import std.file: read;
        this(cast(const(ubyte)[]) read(path), path);
    }

    this(const(ubyte)[] data, string label)
    {
        file = data;
        parse(label);
    }

    bool exists(string path) const
    {
        return (normalizeResourcePath(path) in entries) !is null;
    }

    const(ubyte)[] read(string path) const
    {
        const key = normalizeResourcePath(path);
        auto entry = key in entries;

        if(entry is null)
            throw new PukanException("pack entry not found: " ~ path);

        return file[entry.offset .. entry.offset + entry.size];
    }

    string[] paths() const
    {
        return entries.keys;
    }

    private void parse(string label)
    {
        Reader reader;
        reader.data = file;

        if(reader.u32() != packMagic)
            throw new PukanException(label ~ ": not a Godot PCK");

        const packVersion = reader.u32();
        reader.u32(); // major
        reader.u32(); // minor
        reader.u32(); // patch

        if(packVersion < packVersion2 || packVersion > packVersion4)
            throw new PukanException(label ~ ": unsupported PCK version " ~ packVersion.to!string);

        const flags = reader.u32();
        if((flags & packDirEncrypted) != 0)
            throw new PukanException(label ~ ": encrypted PCK directories are not supported");

        ulong fileBase = reader.u64();
        const start = 0UL;

        if(packVersion == packVersion2)
        {
            if((flags & packRelFileBase) != 0)
                fileBase += start;

            foreach(md5Index; 0 .. 16)
                reader.u32();
        }
        else
        {
            fileBase += start;
            const directoryOffset = reader.u64() + start;

            if((flags & packDirEncrypted) != 0)
                throw new PukanException(label ~ ": encrypted PCK directories are not supported");

            reader.seek(directoryOffset);
        }

        const fileCount = reader.u32();

        foreach(fileIndex; 0 .. fileCount)
        {
            const pathLength = reader.u32();
            const path = reader.readString(pathLength);
            const offset = reader.u64();
            const size = reader.u64();

            foreach(md5Index; 0 .. 16)
                reader.u8(); // md5

            const entryFlags = reader.u32();

            if((entryFlags & packFileRemoval) != 0)
                continue;

            if((entryFlags & (packFileEncrypted | packFileDelta)) != 0)
                throw new PukanException(label ~ ": encrypted and delta PCK entries are not supported");

            const absoluteOffset = fileBase + offset;
            if(absoluteOffset + size > file.length)
                throw new PukanException(label ~ ": PCK entry is out of range");

            entries[normalizeResourcePath(path)] = PckEntry(path, cast(size_t) absoluteOffset, cast(size_t) size);
        }
    }

    private struct Reader
    {
        const(ubyte)[] data;
        size_t pos;

        private void ensure(size_t count) const
        {
            if(pos + count > data.length)
                throw new PukanException("unexpected end of PCK");
        }

        ubyte u8()
        {
            ensure(1);
            return data[pos++];
        }

        uint u32()
        {
            ensure(4);
            const value = cast(uint) data[pos] |
                (cast(uint) data[pos + 1] << 8) |
                (cast(uint) data[pos + 2] << 16) |
                (cast(uint) data[pos + 3] << 24);
            pos += 4;
            return value;
        }

        ulong u64()
        {
            const low = u32();
            const high = u32();
            return low | (cast(ulong) high << 32);
        }

        string readString(size_t length)
        {
            ensure(length);
            const start = pos;
            pos += length;

            // The exporter pads paths to a four-byte boundary with NULs.
            auto end = pos;
            while(end > start && data[end - 1] == 0)
                --end;

            return cast(string) data[start .. end].idup;
        }

        void seek(ulong offset)
        {
            if(offset > data.length)
                throw new PukanException("PCK directory offset is out of range");
            pos = cast(size_t) offset;
        }
    }
}

unittest
{
    import std.path: buildPath, dirName;

    const path = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "demo", "assets", "godot_samples", "generated", "fixtures.pck");
    auto pack = new PckArchive(path);

    assert(pack.exists("res://procedural.tscn"));
    assert(pack.exists("procedural_mesh.res"));
    assert(!pack.exists("res://missing"));
    assert(pack.read("res://procedural.tscn").length > 0);
    assert(pack.read("res://procedural_mesh.res").length > 0);
    assert(pack.read("res://checker.png").length > 0);
}
