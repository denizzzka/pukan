module pukan.godot_scene.value;

import dlib.math: Matrix4x4f, Quaternionf, Vector2f, Vector2i, Vector3f, Vector3i, Vector4f, Vector4i;
import pukan.exceptions: PukanException;
import pukan.misc: Boxf;
import std.conv: to;
import std.variant: Algebraic;

struct GodotNil
{
}

struct GodotStringName
{
    string value;
    alias value this;
}

struct GodotNodePath
{
    string value;
    alias value this;
}

struct GodotColor
{
    float r, g, b, a;

    Vector4f toVector4() const
    {
        return Vector4f(r, g, b, a);
    }
}

struct GodotRect2
{
    Vector2f position;
    Vector2f size;
}

struct GodotRect2i
{
    Vector2i position;
    Vector2i size;
}

struct GodotPlane
{
    Vector3f normal;
    float d;
}

struct GodotBasis
{
    Vector3f[3] rows;

    Matrix4x4f toMatrix() const
    {
        Matrix4x4f m = Matrix4x4f.identity();
        m.a11 = rows[0].x; m.a12 = rows[0].y; m.a13 = rows[0].z;
        m.a21 = rows[1].x; m.a22 = rows[1].y; m.a23 = rows[1].z;
        m.a31 = rows[2].x; m.a32 = rows[2].y; m.a33 = rows[2].z;
        return m;
    }
}

struct GodotTransform2D
{
    Vector2f[3] columns; // x axis, y axis, origin
}

struct GodotTransform3D
{
    Vector3f[3] rows;
    Vector3f origin;

    Matrix4x4f toMatrix() const
    {
        Matrix4x4f m = Matrix4x4f.identity();
        m.a11 = rows[0].x; m.a12 = rows[0].y; m.a13 = rows[0].z;
        m.a21 = rows[1].x; m.a22 = rows[1].y; m.a23 = rows[1].z;
        m.a31 = rows[2].x; m.a32 = rows[2].y; m.a33 = rows[2].z;
        m.a14 = origin.x; m.a24 = origin.y; m.a34 = origin.z;
        return m;
    }
}

struct GodotAabb
{
    Vector3f position;
    Vector3f size;

    Boxf toBox() const
    {
        return Boxf(position, position + size);
    }
}

struct GodotProjection
{
    float[16] values;
}

enum GodotRefKind
{
    subResource,
    extResource,
    resource,
}

struct GodotObjectRef
{
    GodotRefKind kind;
    string id;
}

struct GodotOpaque
{
    string text;
}

final class GodotArray
{
    GodotVariant[] items;

    this(GodotVariant[] items = null)
    {
        this.items = items;
    }

    size_t length() const => items.length;
    ref GodotVariant opIndex(size_t i) => items[i];
    const(GodotVariant) opIndex(size_t i) const => items[i];
    void push(GodotVariant value)
    {
        items ~= value;
    }
}

final class GodotDictionary
{
    GodotVariant[] keys;
    GodotVariant[] values;

    GodotVariant* get(string key)
    {
        foreach(i, k; keys)
            if(k.type == typeid(string) && k.get!string == key)
                return &values[i];

        return null;
    }

    const(GodotVariant)* get(string key) const
    {
        foreach(i, k; keys)
            if(k.type == typeid(string) && k.get!string == key)
                return &values[i];

        return null;
    }

    void set(string key, GodotVariant value)
    {
        foreach(i, k; keys)
            if(k.type == typeid(string) && k.get!string == key)
            {
                values[i] = value;
                return;
            }

        keys ~= GodotVariant(key);
        values ~= GodotVariant(value);
    }

    size_t length() const => keys.length;
}

alias GodotVariant = Algebraic!(
    GodotNil,
    bool,
    long,
    double,
    string,
    GodotStringName,
    GodotNodePath,
    Vector2f,
    Vector2i,
    Vector3f,
    Vector3i,
    Vector4f,
    Vector4i,
    GodotRect2,
    GodotRect2i,
    GodotPlane,
    Quaternionf,
    GodotColor,
    GodotBasis,
    GodotTransform2D,
    GodotTransform3D,
    GodotAabb,
    GodotProjection,
    GodotArray,
    GodotDictionary,
    ubyte[],
    int[],
    long[],
    float[],
    double[],
    string[],
    Vector2f[],
    Vector3f[],
    Vector4f[],
    GodotColor[],
    GodotObjectRef,
    GodotOpaque,
);

string variantTypeName(in GodotVariant value)
{
    if(value.type is typeid(GodotNil)) return "nil";
    if(value.type is typeid(bool)) return "bool";
    if(value.type is typeid(long)) return "int";
    if(value.type is typeid(double)) return "float";
    if(value.type is typeid(string)) return "string";
    if(value.type is typeid(GodotStringName)) return "StringName";
    if(value.type is typeid(GodotNodePath)) return "NodePath";
    if(value.type is typeid(GodotArray)) return "Array";
    if(value.type is typeid(GodotDictionary)) return "Dictionary";
    if(value.type is typeid(ubyte[])) return "PackedByteArray";
    if(value.type is typeid(GodotObjectRef)) return "Object";
    return value.type.toString();
}

T as(T)(in GodotVariant value, string what = "value")
{
    if(value.type !is typeid(T))
        throw new PukanException(what ~ ": expected " ~ T.stringof ~ ", got " ~ variantTypeName(value));

    return value.get!T;
}

bool isNil(in GodotVariant value) => value.type is typeid(GodotNil);

string asString(in GodotVariant value, string what = "value")
{
    if(value.type is typeid(string))
        return value.get!string;
    if(value.type is typeid(GodotStringName))
        return value.get!GodotStringName.value;
    if(value.type is typeid(GodotNodePath))
        return value.get!GodotNodePath.value;

    throw new PukanException(what ~ ": expected string, got " ~ variantTypeName(value));
}

double asDouble(in GodotVariant value, string what = "value")
{
    if(value.type is typeid(double))
        return value.get!double;
    if(value.type is typeid(long))
        return cast(double) value.get!long;

    throw new PukanException(what ~ ": expected number, got " ~ variantTypeName(value));
}

long asLong(in GodotVariant value, string what = "value")
{
    if(value.type is typeid(long))
        return value.get!long;
    if(value.type is typeid(double))
        return cast(long) value.get!double;

    throw new PukanException(what ~ ": expected integer, got " ~ variantTypeName(value));
}

bool asBool(in GodotVariant value, string what = "value")
{
    if(value.type is typeid(bool))
        return value.get!bool;
    if(value.type is typeid(long))
        return value.get!long != 0;

    throw new PukanException(what ~ ": expected bool, got " ~ variantTypeName(value));
}

GodotArray asArray(in GodotVariant value, string what = "value")
{
    if(value.type !is typeid(GodotArray))
        throw new PukanException(what ~ ": expected Array, got " ~ variantTypeName(value));

    return cast(GodotArray) value.get!GodotArray;
}

GodotDictionary asDictionary(in GodotVariant value, string what = "value")
{
    if(value.type !is typeid(GodotDictionary))
        throw new PukanException(what ~ ": expected Dictionary, got " ~ variantTypeName(value));

    return cast(GodotDictionary) value.get!GodotDictionary;
}

GodotObjectRef asObjectRef(in GodotVariant value, string what = "value")
{
    if(value.type !is typeid(GodotObjectRef))
        throw new PukanException(what ~ ": expected Object, got " ~ variantTypeName(value));

    return value.get!GodotObjectRef;
}

string refId(in GodotVariant value, string what = "value")
{
    return asObjectRef(value, what).id;
}

string scalarId(in GodotVariant value, string what = "value")
{
    if(value.type is typeid(string))
        return value.get!string;
    if(value.type is typeid(long))
        return value.get!long.to!string;
    if(value.type is typeid(GodotStringName))
        return value.get!GodotStringName.value;

    throw new PukanException(what ~ ": expected resource id, got " ~ variantTypeName(value));
}
