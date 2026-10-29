module pukan.godot_scene.remap;

import pukan.godot_scene.paths: normalizeResourcePath;
import pukan.godot_scene.source: GodotSource;
import std.string: indexOf, splitLines, startsWith, strip;

/// Follows `<path>.remap` and `<path>.import` to the stored resource
string resolveGodotPath(
    GodotSource source,
    string path,
    bool delegate(string feature) supported = null,
    size_t maxDepth = 8,
)
{
    auto current = "res://" ~ normalizeResourcePath(path);

    foreach(_; 0 .. maxDepth)
    {
        auto target = selectRemap(source, current ~ ".remap", supported);

        if(target.length == 0)
            target = selectRemap(source, current ~ ".import", supported);

        if(target.length == 0 || !source.exists(target))
            break;

        current = target;
    }

    return current;
}

private string selectRemap(
    GodotSource source,
    string remapPath,
    bool delegate(string feature) supported,
)
{
    if(!source.exists(remapPath))
        return "";

    auto entries = remapEntries(source, remapPath);
    string plain;

    foreach(entry; entries)
        if(entry.key == "path")
            plain = entry.path;

    if(plain.length)
        return plain;

    // Desktop S3TC first, then BPTC, ETC2 and ASTC, as Godot exports them.
    foreach(feature; ["s3tc", "bptc", "etc2", "astc", "mobile"])
    {
        if(supported !is null && !supported(feature))
            continue;

        foreach(entry; entries)
            if(entry.key == "path." ~ feature)
                return entry.path;
    }

    return "";
}

private struct RemapEntry
{
    string key;
    string path;
}

private RemapEntry[] remapEntries(GodotSource source, string remapPath)
{
    const text = cast(string) source.read(remapPath);
    RemapEntry[] result;
    bool inRemap;

    foreach(line; text.splitLines)
    {
        const trimmed = line.strip;

        if(trimmed.length == 0 || trimmed.startsWith(";"))
            continue;

        if(trimmed.startsWith("["))
        {
            inRemap = trimmed == "[remap]";
            continue;
        }

        if(!inRemap)
            continue;

        const equals = trimmed.indexOf('=');
        if(equals < 0)
            continue;

        const key = trimmed[0 .. equals].strip;

        if(key != "path" && !key.startsWith("path."))
            continue;

        result ~= RemapEntry(
            key,
            "res://" ~ normalizeResourcePath(unquote(trimmed[equals + 1 .. $].strip)),
        );
    }

    return result;
}

private string unquote(string value)
{
    if(value.length < 2 || value[0] != '"' || value[$ - 1] != '"')
        return value;

    value = value[1 .. $ - 1];

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

unittest
{
    assert(unquote("\"res://a.ctex\"") == "res://a.ctex");
    assert(unquote("\"res://a\\\"b\"") == "res://a\"b");
}

unittest
{
    import pukan.godot_scene.pck: PckArchive;
    import pukan.godot_scene.source: PckSource;
    import std.algorithm: endsWith;
    import std.path: buildPath, dirName;

    const path = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "demo_godot",
        "godot_samples", "exported", "exported.pck");
    auto source = new PckSource(new PckArchive(path));

    assert(resolveGodotPath(source, "res://main.tscn").endsWith(".scn"));
    assert(resolveGodotPath(source, "res://procedural_mesh.tres").endsWith(".res"));
    assert(resolveGodotPath(source, "res://checker.png").endsWith(".ctex"));
    assert(resolveGodotPath(source, "res://missing.tscn") == "res://missing.tscn");
}
