module pukan.godot_scene.project;

import dlib.math: Quaternionf, Vector2f, Vector2i, Vector3f, Vector3i, Vector4f, Vector4i;
import pukan.exceptions: PukanException;
import pukan.godot_scene.source: GodotSource;
import pukan.godot_scene.value: GodotAabb, GodotArray, GodotColor, GodotDictionary, GodotNil,
    GodotPlane, GodotRect2, GodotRect2i, GodotVariant;
import std.algorithm: endsWith;
import std.conv: to;
import std.string: indexOf, splitLines, startsWith, strip;

/// Settings read from `project.binary` or `project.godot`
struct GodotProjectSettings
{
    GodotVariant[string] values;

    string getString(string key, string fallback = "") const
    {
        auto value = key in values;

        if(value is null || (*value).type !is typeid(string))
            return fallback;

        return (*value).get!string;
    }

    string mainScene() const => getString("application/run/main_scene");
    string name() const => getString("application/config/name");
}

/// Loads project settings from a pack or a source project
GodotProjectSettings loadGodotProjectSettings(GodotSource source)
{
    if(source.exists("res://project.binary"))
        return parseGodotProjectBinary(source.read("res://project.binary"), "project.binary");

    if(source.exists("res://project.godot"))
        return parseGodotProjectText(cast(string) source.read("res://project.godot"));

    return GodotProjectSettings.init;
}

/// Parses the compiled `project.binary` (`ECFG`) format
GodotProjectSettings parseGodotProjectBinary(const(ubyte)[] data, string label)
{
    if(data.length < 8 || data[0] != 'E' || data[1] != 'C' || data[2] != 'F' || data[3] != 'G')
        throw new PukanException(label ~ ": not an ECFG file");

    MarshallReader reader;
    reader.data = data;
    reader.pos = 4;
    reader.label = label;

    const count = reader.u32();
    GodotProjectSettings result;

    foreach(_; 0 .. count)
    {
        const key = reader.pascalString();
        const valueLength = reader.u32();
        const valueEnd = reader.pos + valueLength;

        if(valueEnd > data.length)
            throw new PukanException(label ~ ": project setting value is out of range");

        result.values[key] = reader.variant();
        reader.pos = valueEnd;
    }

    return result;
}

/// Reads the string settings of a text `project.godot`
GodotProjectSettings parseGodotProjectText(string text)
{
    GodotProjectSettings result;
    string section;

    foreach(line; text.splitLines)
    {
        const trimmed = line.strip;

        if(trimmed.length == 0 || trimmed.startsWith(";"))
            continue;

        if(trimmed.startsWith("[") && trimmed.endsWith("]"))
        {
            section = trimmed[1 .. $ - 1];
            continue;
        }

        const equals = trimmed.indexOf('=');
        if(equals < 0)
            continue;

        const key = trimmed[0 .. equals].strip;
        auto value = trimmed[equals + 1 .. $].strip;

        if(value.length < 2 || value[0] != '"' || value[$ - 1] != '"')
            continue;

        result.values[section ~ "/" ~ key] = GodotVariant(unquote(value[1 .. $ - 1]));
    }

    return result;
}

private string unquote(string value)
{
    string result;
    result.reserve(value.length);

    for(size_t i; i < value.length; ++i)
    {
        if(value[i] == '\\' && i + 1 < value.length)
        {
            ++i;
            result ~= value[i] == 'n' ? '\n' : value[i];
            continue;
        }

        result ~= value[i];
    }

    return result;
}

// Variant::Type numbering used by the marshalls format, not the RSRC one.
private enum typeNil = 0;
private enum typeBool = 1;
private enum typeInt = 2;
private enum typeFloat = 3;
private enum typeString = 4;
private enum typeVector2 = 5;
private enum typeVector2i = 6;
private enum typeRect2 = 7;
private enum typeRect2i = 8;
private enum typeVector3 = 9;
private enum typeVector3i = 10;
private enum typeTransform2d = 11;
private enum typeVector4 = 12;
private enum typeVector4i = 13;
private enum typePlane = 14;
private enum typeQuaternion = 15;
private enum typeAabb = 16;
private enum typeBasis = 17;
private enum typeTransform3d = 18;
private enum typeProjection = 19;
private enum typeColor = 20;
private enum typeStringName = 21;
private enum typeNodePath = 22;
private enum typeRid = 23;
private enum typeObject = 24;
private enum typeCallable = 25;
private enum typeSignal = 26;
private enum typeDictionary = 27;
private enum typeArray = 28;
private enum typePackedByteArray = 29;
private enum typePackedInt32Array = 30;
private enum typePackedInt64Array = 31;
private enum typePackedFloat32Array = 32;
private enum typePackedFloat64Array = 33;
private enum typePackedStringArray = 34;
private enum typePackedVector2Array = 35;
private enum typePackedVector3Array = 36;
private enum typePackedColorArray = 37;
private enum typePackedVector4Array = 38;

private enum headerTypeMask = 0xFF;
private enum headerFlag64 = 1 << 16;

private struct MarshallReader
{
    const(ubyte)[] data;
    size_t pos;
    string label;

    private void ensure(size_t count) const
    {
        if(pos + count > data.length)
            throw new PukanException(label ~ ": unexpected end of a variant");
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

    private string pascalString()
    {
        const length = u32();
        ensure(length);

        auto end = pos + length;
        while(end > pos && data[end - 1] == 0)
            --end;

        const value = cast(string) data[pos .. end].idup;
        pos += length;
        return value;
    }

    private string readString()
    {
        const length = u32();
        ensure(length);

        auto end = pos + length;
        while(end > pos && data[end - 1] == 0)
            --end;

        const value = cast(string) data[pos .. end].idup;
        pos += length;
        pos += (4 - length % 4) % 4;
        return value;
    }

    private GodotVariant variant()
    {
        const header = u32();

        switch(header & headerTypeMask)
        {
            case typeNil:
                return GodotVariant(GodotNil());

            case typeBool:
                return GodotVariant(u32() != 0);

            case typeInt:
                return (header & headerFlag64)
                    ? GodotVariant(cast(long) u64())
                    : GodotVariant(cast(long) cast(int) u32());

            case typeFloat:
                return (header & headerFlag64)
                    ? GodotVariant(f64())
                    : GodotVariant(cast(double) f32());

            case typeString:
            case typeStringName:
                return GodotVariant(readString());

            case typeDictionary:
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

            case typeArray:
            {
                const length = u32() & 0x7FFFFFFF;
                auto result = new GodotArray;

                foreach(_; 0 .. length)
                    result.items ~= variant();

                return GodotVariant(result);
            }

            case typePackedByteArray:
            {
                const length = u32();
                ensure(length);
                const start = pos;
                pos += length;
                pos += (4 - length % 4) % 4;
                return GodotVariant(cast(ubyte[]) data[start .. start + length].dup);
            }

            case typePackedInt32Array:
            {
                const length = u32();
                int[] result;
                result.length = length;

                foreach(i; 0 .. length)
                    result[i] = cast(int) u32();

                return GodotVariant(result);
            }

            case typePackedInt64Array:
            {
                const length = u32();
                long[] result;
                result.length = length;

                foreach(i; 0 .. length)
                    result[i] = cast(long) u64();

                return GodotVariant(result);
            }

            case typePackedFloat32Array:
            {
                const length = u32();
                float[] result;
                result.length = length;

                foreach(i; 0 .. length)
                    result[i] = f32();

                return GodotVariant(result);
            }

            case typePackedFloat64Array:
            {
                const length = u32();
                double[] result;
                result.length = length;

                foreach(i; 0 .. length)
                    result[i] = f64();

                return GodotVariant(result);
            }

            case typePackedStringArray:
            {
                const length = u32();
                string[] result;
                result.length = length;

                foreach(i; 0 .. length)
                    result[i] = readString();

                return GodotVariant(result);
            }

            case typePackedColorArray:
            {
                const length = u32();
                GodotColor[] result;
                result.length = length;

                foreach(i; 0 .. length)
                {
                    result[i].r = f32();
                    result[i].g = f32();
                    result[i].b = f32();
                    result[i].a = f32();
                }

                return GodotVariant(result);
            }

            case typeVector2:
                return GodotVariant(Vector2f(f32(), f32()));

            case typeVector3:
                return GodotVariant(Vector3f(f32(), f32(), f32()));

            case typeVector4:
                return GodotVariant(Vector4f(f32(), f32(), f32(), f32()));

            case typeVector2i:
                return GodotVariant(Vector2i(cast(int) u32(), cast(int) u32()));

            case typeVector3i:
                return GodotVariant(Vector3i(cast(int) u32(), cast(int) u32(), cast(int) u32()));

            case typeVector4i:
                return GodotVariant(Vector4i(cast(int) u32(), cast(int) u32(), cast(int) u32(), cast(int) u32()));

            case typeRect2:
                return GodotVariant(GodotRect2(Vector2f(f32(), f32()), Vector2f(f32(), f32())));

            case typeRect2i:
                return GodotVariant(GodotRect2i(
                    Vector2i(cast(int) u32(), cast(int) u32()),
                    Vector2i(cast(int) u32(), cast(int) u32()),
                ));

            case typePlane:
                return GodotVariant(GodotPlane(Vector3f(f32(), f32(), f32()), f32()));

            case typeQuaternion:
                return GodotVariant(Quaternionf(f32(), f32(), f32(), f32()));

            case typeAabb:
                return GodotVariant(GodotAabb(Vector3f(f32(), f32(), f32()), Vector3f(f32(), f32(), f32())));

            case typeColor:
                return GodotVariant(GodotColor(f32(), f32(), f32(), f32()));

            default:
                throw new PukanException(label ~ ": unsupported project setting type " ~ (header & headerTypeMask).to!string);
        }
    }
}

unittest
{
    import pukan.godot_scene.pck: PckArchive;
    import std.file: read;
    import std.path: buildPath, dirName;

    const root = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "demo", "assets", "godot_samples", "exported");
    const pack = new PckArchive(buildPath(root, "exported.pck"));

    const settings = parseGodotProjectBinary(pack.read("res://project.binary"), "project.binary");
    assert(settings.name == "pukan exported fixture");
    assert(settings.mainScene == "res://main.tscn");

    const features = settings.values["application/config/features"].get!(string[]);
    assert(features == ["4.7"]);

    const text = parseGodotProjectText(cast(string) read(buildPath(root, "project.godot")));
    assert(text.mainScene == "res://main.tscn");
    assert(text.name == "pukan exported fixture");
}
