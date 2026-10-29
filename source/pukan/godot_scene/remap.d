module pukan.godot_scene.remap;

import pukan.godot_scene.paths: normalizeResourcePath;
import pukan.godot_scene.source: GodotSource;
import std.string: indexOf, splitLines, startsWith, strip;

/// Follows `<path>.remap` and `<path>.import` to the stored resource
string resolveGodotPath(GodotSource source, string path, size_t maxDepth = 8)
{
    auto current = "res://" ~ normalizeResourcePath(path);

    foreach(_; 0 .. maxDepth)
    {
        auto target = remapTarget(source, current ~ ".remap");

        if(target.length == 0)
            target = remapTarget(source, current ~ ".import");

        if(target.length == 0 || !source.exists(target))
            break;

        current = target;
    }

    return current;
}

/// Reads the `path` of the `[remap]` section, empty when absent
string remapTarget(GodotSource source, string remapPath)
{
    if(!source.exists(remapPath))
        return "";

    const text = cast(string) source.read(remapPath);
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

        if(trimmed[0 .. equals].strip != "path")
            continue;

        return "res://" ~ normalizeResourcePath(unquote(trimmed[equals + 1 .. $].strip));
    }

    return "";
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

    const path = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "demo", "assets",
        "godot_samples", "exported", "exported.pck");
    auto source = new PckSource(new PckArchive(path));

    assert(resolveGodotPath(source, "res://main.tscn").endsWith(".scn"));
    assert(resolveGodotPath(source, "res://procedural_mesh.tres").endsWith(".res"));
    assert(resolveGodotPath(source, "res://checker.png").endsWith(".ctex"));
    assert(resolveGodotPath(source, "res://missing.tscn") == "res://missing.tscn");
}
