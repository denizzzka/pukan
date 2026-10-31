module pukan.godot_scene.source;

import pukan.godot_scene.paths: normalizeResourcePath;
import pukan.godot_scene.pck: PckArchive;

/// A source of `res://` resources, either a project directory or a pack
interface GodotSource
{
    bool exists(string path);
    const(ubyte)[] read(string path);
}

/// Maps `res://` paths to a project directory
final class DirectorySource : GodotSource
{
    private string root;

    this(string root)
    {
        this.root = root;
    }

    bool exists(string path)
    {
        import std.file: exists;
        return exists(physical(path));
    }

    const(ubyte)[] read(string path)
    {
        import std.file: read;
        return cast(const(ubyte)[]) read(physical(path));
    }

    /// Filesystem path for loaders that take a filename
    string physical(string path)
    {
        import std.path: buildPath;
        return buildPath(root, normalizeResourcePath(path));
    }
}

/// Maps `res://` paths to a pack archive
final class PckSource : GodotSource
{
    private PckArchive archive;

    this(PckArchive archive)
    {
        this.archive = archive;
    }

    this(string path)
    {
        archive = new PckArchive(path);
    }

    bool exists(string path)
    {
        return archive.exists(path);
    }

    const(ubyte)[] read(string path)
    {
        return archive.read(path);
    }
}
