module pukan;

public import pukan.vulkan;

import pukan.vulkan.bindings;

import std.typecons;

alias DeltaTime = Typedef!(float, float.init, "delta time");

//~ struct VulkanContext
//~ {
    //~ VkInstance instance;
//~ }

struct MuteLogger
{
    void info(T...)(T s) {}
}

string toPrettyString(T)(in T val)
{
    import mir.ser.json: serializeJsonPretty;
    import std.conv: to;

    return val.serializeJsonPretty.to!string;
}
