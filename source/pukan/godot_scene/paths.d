module pukan.godot_scene.paths;

/// Normalizes a `res://` path to a path relative to its project root
string normalizeResourcePath(string path)
{
    import std.algorithm: splitter;
    import std.array: join;
    import std.string: startsWith;

    if(path.startsWith("res://"))
        path = path[6 .. $];

    string[] parts;

    foreach(part; splitter(path, "/"))
    {
        if(part.length == 0 || part == ".")
            continue;

        if(part == "..")
        {
            if(parts.length)
                parts.length--;
            continue;
        }

        parts ~= part;
    }

    return parts.join("/");
}

unittest
{
    assert(normalizeResourcePath("res://a/b/../c") == "a/c");
    assert(normalizeResourcePath("/a//b") == "a/b");
    assert(normalizeResourcePath("res://") == "");
}
