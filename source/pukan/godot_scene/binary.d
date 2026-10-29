module pukan.godot_scene.binary;

import dlib.math: Quaternionf, Vector2f, Vector2i, Vector3f, Vector3i, Vector4f, Vector4i;
import pukan.exceptions: PukanException;
import pukan.godot_scene.text: GodotTextDocument, GodotTextExternal, GodotTextResource, parseGodotText;
import pukan.godot_scene.value;
import std.conv: to;

private enum variantNil = 1;
private enum variantBool = 2;
private enum variantInt = 3;
private enum variantFloat = 4;
private enum variantString = 5;
private enum variantVector2 = 10;
private enum variantRect2 = 11;
private enum variantVector3 = 12;
private enum variantPlane = 13;
private enum variantQuaternion = 14;
private enum variantAabb = 15;
private enum variantBasis = 16;
private enum variantTransform3d = 17;
private enum variantTransform2d = 18;
private enum variantColor = 20;
private enum variantNodePath = 22;
private enum variantRid = 23;
private enum variantObject = 24;
private enum variantInputEvent = 25;
private enum variantDictionary = 26;
private enum variantArray = 30;
private enum variantPackedByteArray = 31;
private enum variantPackedInt32Array = 32;
private enum variantPackedFloat32Array = 33;
private enum variantPackedStringArray = 34;
private enum variantPackedVector3Array = 35;
private enum variantPackedColorArray = 36;
private enum variantPackedVector2Array = 37;
private enum variantInt64 = 40;
private enum variantDouble = 41;
private enum variantCallable = 42;
private enum variantSignal = 43;
private enum variantStringName = 44;
private enum variantVector2i = 45;
private enum variantRect2i = 46;
private enum variantVector3i = 47;
private enum variantPackedInt64Array = 48;
private enum variantPackedFloat64Array = 49;
private enum variantVector4 = 50;
private enum variantVector4i = 51;
private enum variantProjection = 52;
private enum variantPackedVector4Array = 53;

private enum objectEmpty = 0;
private enum objectExternalResource = 1;
private enum objectInternalResource = 2;
private enum objectExternalResourceIndex = 3;

private enum formatFlagUids = 2;
private enum formatFlagRealIsDouble = 4;
private enum formatFlagHasScriptClass = 8;
private enum reservedFields = 11;
private enum supportedFormatVersion = 6;

private enum nameIndexBits = 18;
private enum nameIndexMask = (1 << nameIndexBits) - 1;
private enum noParentSaved = 0x7FFFFFFF;
private enum typeInstantiated = 0x7FFFFFFF;
private enum flagInstanceIsPlaceholder = 1 << 30;
private enum flagIdIsPath = 1 << 30;
private enum variantIndexMask = (1 << 24) - 1;

/// Reads a Godot text or binary resource, choosing by the file magic
GodotTextDocument parseGodotResourceData(const(ubyte)[] data, string label)
{
    if(data.length >= 4 && data[0] == 'R' && data[1] == 'S' && data[2] == 'R' && data[3] == 'C')
        return parseGodotBinary(data, label);

    if(data.length >= 4 && data[0] == 'R' && data[1] == 'S' && data[2] == 'C' && data[3] == 'C')
    {
        const decoded = decompressGodotResource(data, label);
        auto resource = new ubyte[decoded.length + 4];
        resource[0 .. 4] = ['R', 'S', 'R', 'C'];
        resource[4 .. $] = decoded;
        return parseGodotBinary(resource, label, 4);
    }

    return parseGodotText(cast(string) data);
}

GodotTextDocument parseGodotResourceFile(string path)
{
    import std.file: read;
    return parseGodotResourceData(cast(ubyte[]) read(path), path);
}

/// Decodes the RSCC block stream of a compressed resource
private ubyte[] decompressGodotResource(const(ubyte)[] data, string label)
{
    import pukan.zstd: decompressZstd;
    import std.algorithm: min;

    size_t pos = 4;

    uint u32()
    {
        if(pos + 4 > data.length)
            throw new PukanException(label ~ ": unexpected end of compressed resource");

        const value = cast(uint) data[pos] |
            (cast(uint) data[pos + 1] << 8) |
            (cast(uint) data[pos + 2] << 16) |
            (cast(uint) data[pos + 3] << 24);
        pos += 4;
        return value;
    }

    const mode = u32();
    const blockSize = u32();
    const total = u32();

    if(blockSize == 0)
        throw new PukanException(label ~ ": compressed resource has a zero block size");

    const blockCount = total / blockSize + 1;
    uint[] compressedSizes;
    compressedSizes.length = blockCount;

    foreach(i; 0 .. blockCount)
        compressedSizes[i] = u32();

    auto result = new ubyte[total];
    size_t sourceOffset = pos;

    foreach(i; 0 .. blockCount)
    {
        const destinationOffset = i * blockSize;
        const destinationSize = min(blockSize, total - destinationOffset);

        if(destinationSize == 0)
        {
            sourceOffset += compressedSizes[i];
            continue;
        }

        const block = data[sourceOffset .. sourceOffset + compressedSizes[i]];
        auto destination = result[destinationOffset .. destinationOffset + destinationSize];

        if(mode == 2) // Zstandard
        {
            if(!decompressZstd(block, destination))
                throw new PukanException(label ~ ": failed to decompress a Zstandard block");
        }
        else
            throw new PukanException(label ~ ": unsupported compressed resource mode " ~ mode.to!string);

        sourceOffset += compressedSizes[i];
    }

    return result;
}

GodotTextDocument parseGodotBinary(const(ubyte)[] data, string path, size_t offsetBias = 0)
{
    BinaryReader reader;
    reader.data = data;
    reader.offsetBias = offsetBias;
    return reader.parse(path);
}


private struct BinaryReader
{
    const(ubyte)[] data;
    size_t pos;
    bool realIsDouble;
    string[] strings;
    GodotTextExternal[] externals;
    size_t offsetBias;

    private void ensure(size_t count) const
    {
        if(pos + count > data.length)
            throw new PukanException("unexpected end of binary resource");
    }

    private ubyte u8()
    {
        ensure(1);
        return data[pos++];
    }

    private ushort u16()
    {
        ensure(2);
        const value = cast(ushort) (data[pos] | (data[pos + 1] << 8));
        pos += 2;
        return value;
    }

    private uint u32()
    {
        ensure(4);
        const value = cast(uint) data[pos] |
            (cast(uint) data[pos + 1] << 8) |
            (cast(uint) data[pos + 2] << 16) |
            (cast(uint) data[pos + 3] << 24);
        pos += 4;
        return value;
    }

    private ulong u64()
    {
        const low = u32();
        const high = u32();
        return low | (cast(ulong) high << 32);
    }

    private int i32() => cast(int) u32();
    private long i64() => cast(long) u64();

    private float f32()
    {
        union Bits
        {
            uint u;
            float f;
        }

        Bits bits;
        bits.u = u32();
        return bits.f;
    }

    private double f64()
    {
        union Bits
        {
            ulong u;
            double f;
        }

        Bits bits;
        bits.u = u64();
        return bits.f;
    }

    private double realValue() => realIsDouble ? f64() : f32();

    private void padding(size_t length)
    {
        const extra = (4 - length % 4) % 4;
        ensure(extra);
        pos += extra;
    }

    private string text()
    {
        const length = u32();
        if(length == 0)
            return "";

        ensure(length);
        const start = pos;
        pos += length;

        const hasNul = data[pos - 1] == 0;
        return cast(string) data[start .. pos - (hasNul ? 1 : 0)].idup;
    }

    private string stringName()
    {
        const id = u32();

        if((id & 0x80000000) != 0)
        {
            const length = id & 0x7FFFFFFF;
            if(length == 0)
                return "";

            ensure(length);
            const start = pos;
            pos += length;
            const hasNul = data[pos - 1] == 0;
            return cast(string) data[start .. pos - (hasNul ? 1 : 0)].idup;
        }

        if(id >= strings.length)
            throw new PukanException("binary string index is out of range");

        return strings[id];
    }

    private GodotVariant variant()
    {
        const type = u32();

        switch(type)
        {
            case variantNil:
                return GodotVariant(GodotNil());

            case variantBool:
                return GodotVariant(u32() != 0);

            case variantInt:
                return GodotVariant(cast(long) i32());

            case variantInt64:
                return GodotVariant(i64());

            case variantFloat:
                return GodotVariant(realValue());

            case variantDouble:
                return GodotVariant(f64());

            case variantString:
                return GodotVariant(text());

            case variantStringName:
                return GodotVariant(GodotStringName(text()));

            case variantVector2:
                return GodotVariant(Vector2f(cast(float) realValue(), cast(float) realValue()));

            case variantVector2i:
                return GodotVariant(Vector2i(i32(), i32()));

            case variantVector3:
                return GodotVariant(Vector3f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue()));

            case variantVector3i:
                return GodotVariant(Vector3i(i32(), i32(), i32()));

            case variantVector4:
                return GodotVariant(Vector4f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue(), cast(float) realValue()));

            case variantVector4i:
                return GodotVariant(Vector4i(i32(), i32(), i32(), i32()));

            case variantRect2:
                return GodotVariant(GodotRect2(
                    Vector2f(cast(float) realValue(), cast(float) realValue()),
                    Vector2f(cast(float) realValue(), cast(float) realValue()),
                ));

            case variantRect2i:
                return GodotVariant(GodotRect2i(
                    Vector2i(i32(), i32()),
                    Vector2i(i32(), i32()),
                ));

            case variantPlane:
                return GodotVariant(GodotPlane(
                    Vector3f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue()),
                    cast(float) realValue(),
                ));

            case variantQuaternion:
                return GodotVariant(Quaternionf(
                    cast(float) realValue(), cast(float) realValue(), cast(float) realValue(), cast(float) realValue(),
                ));

            case variantAabb:
                return GodotVariant(GodotAabb(
                    Vector3f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue()),
                    Vector3f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue()),
                ));

            case variantTransform2d:
                return GodotVariant(GodotTransform2D([
                    Vector2f(cast(float) realValue(), cast(float) realValue()),
                    Vector2f(cast(float) realValue(), cast(float) realValue()),
                    Vector2f(cast(float) realValue(), cast(float) realValue()),
                ]));

            case variantBasis:
            {
                // Binary resources store the basis rows as they are laid out in memory
                GodotBasis basis;
                basis.rows[0] = Vector3f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue());
                basis.rows[1] = Vector3f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue());
                basis.rows[2] = Vector3f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue());
                return GodotVariant(basis);
            }

            case variantTransform3d:
            {
                GodotTransform3D transform;
                transform.rows[0] = Vector3f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue());
                transform.rows[1] = Vector3f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue());
                transform.rows[2] = Vector3f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue());
                transform.origin = Vector3f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue());
                return GodotVariant(transform);
            }

            case variantProjection:
                GodotProjection projection;
                foreach(i; 0 .. 16)
                    projection.values[i] = cast(float) realValue();
                return GodotVariant(projection);

            case variantColor:
                return GodotVariant(GodotColor(f32(), f32(), f32(), f32()));

            case variantNodePath:
                return GodotVariant(GodotNodePath(nodePath()));

            case variantRid:
                u32();
                return GodotVariant(GodotOpaque("RID"));

            case variantObject:
                return objectVariant();

            case variantCallable:
                return GodotVariant(GodotOpaque("Callable"));

            case variantSignal:
                return GodotVariant(GodotOpaque("Signal"));

            case variantDictionary:
            {
                const length = u32() & 0x7FFFFFFF;
                auto result = new GodotDictionary;

                foreach(_; 0 .. length)
                {
                    result.keys ~= variant();
                    result.values ~= variant();
                }

                return GodotVariant(result);
            }

            case variantArray:
            {
                const length = u32() & 0x7FFFFFFF;
                auto result = new GodotArray;

                foreach(_; 0 .. length)
                    result.items ~= variant();

                return GodotVariant(result);
            }

            case variantPackedByteArray:
            {
                const length = u32();
                ensure(length);
                const start = pos;
                pos += length;
                padding(length);
                return GodotVariant(cast(ubyte[]) data[start .. start + length].dup);
            }

            case variantPackedInt32Array:
            {
                const length = u32();
                int[] result;
                result.length = length;
                foreach(i; 0 .. length)
                    result[i] = i32();
                return GodotVariant(result);
            }

            case variantPackedInt64Array:
            {
                const length = u32();
                long[] result;
                result.length = length;
                foreach(i; 0 .. length)
                    result[i] = i64();
                return GodotVariant(result);
            }

            case variantPackedFloat32Array:
            {
                const length = u32();
                float[] result;
                result.length = length;
                foreach(i; 0 .. length)
                    result[i] = f32();
                return GodotVariant(result);
            }

            case variantPackedFloat64Array:
            {
                const length = u32();
                double[] result;
                result.length = length;
                foreach(i; 0 .. length)
                    result[i] = f64();
                return GodotVariant(result);
            }

            case variantPackedStringArray:
            {
                const length = u32();
                string[] result;
                result.length = length;
                foreach(i; 0 .. length)
                    result[i] = text();
                return GodotVariant(result);
            }

            case variantPackedVector2Array:
            {
                const length = u32();
                Vector2f[] result;
                result.length = length;
                foreach(i; 0 .. length)
                    result[i] = Vector2f(cast(float) realValue(), cast(float) realValue());
                return GodotVariant(result);
            }

            case variantPackedVector3Array:
            {
                const length = u32();
                Vector3f[] result;
                result.length = length;
                foreach(i; 0 .. length)
                    result[i] = Vector3f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue());
                return GodotVariant(result);
            }

            case variantPackedVector4Array:
            {
                const length = u32();
                Vector4f[] result;
                result.length = length;
                foreach(i; 0 .. length)
                    result[i] = Vector4f(cast(float) realValue(), cast(float) realValue(), cast(float) realValue(), cast(float) realValue());
                return GodotVariant(result);
            }

            case variantPackedColorArray:
            {
                const length = u32();
                GodotColor[] result;
                result.length = length;
                foreach(i; 0 .. length)
                    result[i] = GodotColor(f32(), f32(), f32(), f32());
                return GodotVariant(result);
            }

            case variantInputEvent:
                return GodotVariant(GodotOpaque("InputEvent"));

            default:
                throw new PukanException("unsupported binary variant type " ~ type.to!string);
        }
    }

    private string nodePath()
    {
        const nameCount = u16();
        ushort subnameCount = u16();
        const absolute = (subnameCount & 0x8000) != 0;
        subnameCount &= 0x7FFF;

        string result;

        if(absolute)
            result ~= "/";

        foreach(i; 0 .. nameCount)
        {
            if(i)
                result ~= "/";
            result ~= stringName();
        }

        foreach(i; 0 .. subnameCount)
            result ~= ":" ~ stringName();

        return result;
    }

    private GodotVariant objectVariant()
    {
        const objectType = u32();

        switch(objectType)
        {
            case objectEmpty:
                return GodotVariant(GodotNil());

            case objectInternalResource:
                return GodotVariant(GodotObjectRef(GodotRefKind.subResource, u32().to!string));

            case objectExternalResourceIndex:
                return GodotVariant(GodotObjectRef(GodotRefKind.extResource, u32().to!string));

            case objectExternalResource:
            {
                const type = text();
                const path = text();

                externals ~= GodotTextExternal(type, path, path, "");

                return GodotVariant(GodotObjectRef(GodotRefKind.extResource, path));
            }

            default:
                throw new PukanException("unsupported binary object kind " ~ objectType.to!string);
        }
    }

    private void seek(ulong offset)
    {
        if(offset > data.length)
            throw new PukanException("binary resource offset is out of range");
        pos = cast(size_t) offset;
    }

    private GodotTextDocument parse(string path)
    {
        if(data.length < 4 || data[0] != 'R' || data[1] != 'S' || data[2] != 'R' || data[3] != 'C')
            throw new PukanException(path ~ ": not an RSRC file");

        pos = 4;

        const bigEndian = u32();
        if(bigEndian != 0)
            throw new PukanException(path ~ ": big-endian binary resources are not supported");

        u32(); // use_real64, the format flag below is authoritative
        const versionMajor = u32();
        u32(); // version minor
        const formatVersion = u32();

        if(versionMajor > 4 || formatVersion > supportedFormatVersion)
            throw new PukanException(path ~ ": unsupported RSRC format " ~ formatVersion.to!string);

        const mainType = text();
        u64(); // import metadata offset
        const flags = u32();
        u64(); // uid
        realIsDouble = (flags & formatFlagRealIsDouble) != 0;

        if((flags & formatFlagHasScriptClass) != 0)
            text();

        foreach(_; 0 .. reservedFields)
            u32();

        const stringCount = u32();
        strings.length = stringCount;
        foreach(i; 0 .. stringCount)
            strings[i] = text();

        const externalCount = u32();
        externals.length = externalCount;
        foreach(i; 0 .. externalCount)
        {
            const type = text();
            const resourcePath = text();
            ulong uid;
            if((flags & formatFlagUids) != 0)
                uid = u64();
            externals[i] = GodotTextExternal(type, resourcePath, i.to!string, uid ? uid.to!string : "");
        }

        const internalCount = u32();
        struct Internal
        {
            string path;
            ulong offset;
        }
        Internal[] internal;
        internal.length = internalCount;
        foreach(i; 0 .. internalCount)
            internal[i] = Internal(text(), u64());

        GodotTextDocument result;
        result.binary = true;
        result.binaryVersion = formatVersion;
        result.format = 0;
        result.resourceType = mainType;
        result.isScene = mainType == "PackedScene";
        result.externals = externals;

        foreach(i, ref resource; internal)
        {
            seek(resource.offset + offsetBias);
            const type = text();
            const propertyCount = u32();

            GodotTextResource subResource;
            subResource.type = type;
            subResource.id = i.to!string;

            foreach(_; 0 .. propertyCount)
            {
                const name = stringName();
                subResource.properties[name] = variant();
            }

            result.subResources ~= subResource;

            if(i + 1 == internalCount)
            {
                result.resourceType = type;
                result.resourceProperties = subResource.properties;
            }
        }

        if(result.resourceType == "PackedScene")
            decodePackedScene(result);

        return result;
    }

    private static T required(T)(GodotDictionary dictionary, string name)
    {
        auto value = dictionary.get(name);
        if(value is null)
            throw new PukanException("PackedScene is missing " ~ name);
        if((*value).type !is typeid(T))
            throw new PukanException(name ~ ": unexpected binary value type");
        return cast(T) (*value).get!T;
    }

    private static void decodePackedScene(ref GodotTextDocument document)
    {
        auto bundledValue = "_bundled" in document.resourceProperties;
        if(bundledValue is null)
            throw new PukanException("PackedScene has no _bundled dictionary");

        auto bundled = asDictionary(*bundledValue, "_bundled");
        auto names = required!(string[])(bundled, "names");
        auto variants = required!(GodotArray)(bundled, "variants");
        GodotNodePath[] nodePaths;

        if(auto value = bundled.get("node_paths"))
        {
            foreach(item; asArray(*value, "node_paths").items)
                nodePaths ~= as!(GodotNodePath)(item, "node_path");
        }
        const nodeCount = cast(size_t) required!long(bundled, "node_count");
        auto records = required!(int[])(bundled, "nodes");

        document.nodes.length = nodeCount;
        string[] paths;
        paths.length = nodeCount;

        size_t cursor;

        foreach(i; 0 .. nodeCount)
        {
            int next()
            {
                if(cursor >= records.length)
                    throw new PukanException("PackedScene node table is truncated");
                return records[cursor++];
            }

            const parent = next();
            next(); // owner
            const typeIndex = next();
            const namePacked = cast(uint) next();
            const instance = next();
            const propertyCount = next();

            if(cursor > records.length)
                throw new PukanException("PackedScene node table is truncated");

            const nameIndex = namePacked & nameIndexMask;
            if(nameIndex >= names.length)
                throw new PukanException("PackedScene node name index is out of range");

            ref node = document.nodes[i];
            node.name = names[nameIndex];
            node.type = typeIndex == typeInstantiated ? "" : names[cast(size_t) typeIndex];

            if(parent < 0 || parent == noParentSaved)
            {
                node.parent = "";
                paths[i] = ".";
            }
            else if((parent & flagIdIsPath) != 0)
            {
                const pathIndex = parent & (flagIdIsPath - 1);

                if(pathIndex >= nodePaths.length)
                    throw new PukanException("PackedScene parent path index is out of range");

                node.parent = nodePaths[pathIndex].value;
                paths[i] = node.parent.length ? node.parent ~ "/" ~ node.name : node.name;
            }
            else
            {
                if(cast(size_t) parent >= i)
                    throw new PukanException("PackedScene parent is not before the child");

                node.parent = parent == 0 ? "." : paths[cast(size_t) parent];
                paths[i] = node.parent == "." ? node.name : node.parent ~ "/" ~ node.name;
            }

            if(instance >= 0 && (instance & flagInstanceIsPlaceholder) == 0)
            {
                const variantIndex = instance & variantIndexMask;
                if(variantIndex >= variants.length)
                    throw new PukanException("PackedScene instance index is out of range");

                node.instance = variants[variantIndex];
            }

            foreach(_; 0 .. propertyCount)
            {
                const propertyName = next();
                const propertyValue = next();

                if(propertyName < 0 || propertyValue < 0 ||
                    cast(size_t) propertyName >= names.length ||
                    cast(size_t) propertyValue >= variants.length)
                    throw new PukanException("PackedScene property index is out of range");

                node.properties[names[cast(size_t) propertyName]] = variants[cast(size_t) propertyValue];
            }

            const groupCount = next();
            foreach(_; 0 .. groupCount)
                next();
        }
    }
}

unittest
{
    const document = parseGodotResourceFile(fixturePath("generated/procedural_mesh.res"));
    assert(document.binary);
    assert(document.binaryVersion == 6);
    assert(document.resourceType == "ArrayMesh");

    const surfaces = document.resourceProperties["_surfaces"].get!GodotArray;
    assert(surfaces.length == 2);

    const first = surfaces[0].get!GodotDictionary;
    assert((*first.get("format")).get!long == 34359742495);
    assert((*first.get("vertex_count")).get!long == 4);
    assert((*first.get("vertex_data")).get!(ubyte[]).length == 80);
    assert((*first.get("index_data")).get!(ubyte[]).length == 12);
}

unittest
{
    const document = parseGodotResourceFile(fixturePath("generated/procedural.scn"));
    assert(document.binary);
    assert(document.isScene);
    assert(document.resourceType == "PackedScene");

    const bundled = document.resourceProperties["_bundled"].get!GodotDictionary;
    assert((*bundled.get("node_count")).get!long == 2);
    assert((*bundled.get("nodes")).get!(int[]).length > 0);

    assert(document.nodes.length == 2);
    assert(document.nodes[0].name == "Root");
    assert(document.nodes[0].type == "Node3D");
    assert(document.nodes[1].name == "Procedural");
    assert(document.nodes[1].type == "MeshInstance3D");
    assert(document.nodes[1].parent == ".");
    assert(document.nodes[1].properties["mesh"].type is typeid(GodotObjectRef));
    assert(document.nodes[1].properties["transform"].type is typeid(GodotTransform3D));
}

private string fixturePath(string relative)
{
    import std.path: buildPath, dirName;
    return buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "demo", "assets", "godot_samples", relative);
}

unittest
{
    import pukan.godot_scene.scene: GodotScene;
    // The scene node tree is decoded by parseGodotResourceFile through the
    // generic binary resource path; see the loader tests.
}
