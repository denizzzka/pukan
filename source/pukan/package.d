module pukan;

public import pukan.background;
public import pukan.gltf;
public import pukan.godot_scene;
public import pukan.material;
public import pukan.mesh;
public import pukan.misc;
public import pukan.pbr;
public import pukan.primitives_tree;
public import pukan.primitives_tree.mesh;
public import pukan.primitives_tree.tree;
public import pukan.scene;
public import pukan.screenshot;
public import pukan.stereo;
public import pukan.vulkan;

import pukan.vulkan.bindings;

import std.typecons;

alias DeltaTime = Typedef!(float, float.init, "delta time");

string toPrettyString(T)(in T val)
{
    import mir.ser.json: serializeJsonPretty;
    import std.conv: to;

    return val.serializeJsonPretty.to!string;
}
