module pukan.godot_scene.mesh;

import dlib.math: Vector2f, Vector3f, Vector4f;
import pukan.exceptions: PukanException;
import pukan.godot_scene.value;
import pukan.pbr.mesh: MeshGeometry, Vector4us;
import std.math: abs;
import std.conv: to;

enum GodotPrimitive
{
    points,
    lines,
    lineStrip,
    triangles,
    triangleStrip,
}

struct GodotArraySurface
{
    GodotPrimitive primitive;
    MeshGeometry geometry;
    GodotObjectRef material;
    bool hasMaterial;
    string name;
    GodotAabb aabb;
}

private enum arrayVertex = 1UL << 0;
private enum arrayNormal = 1UL << 1;
private enum arrayTangent = 1UL << 2;
private enum arrayColor = 1UL << 3;
private enum arrayTexUv = 1UL << 4;
private enum arrayTexUv2 = 1UL << 5;
private enum arrayCustom0 = 1UL << 6;
private enum arrayBones = 1UL << 10;
private enum arrayWeights = 1UL << 11;
private enum arrayIndex = 1UL << 12;
private enum flag2dVertices = 1UL << 25;
private enum flag8BoneWeights = 1UL << 27;
private enum flagCompressAttributes = 1UL << 29;
private enum formatVersionShift = 35;
private enum formatVersionMask = 0xFF;

private GodotVariant* property(GodotDictionary dictionary, string name)
{
    return dictionary.get(name);
}

private T propertyAs(T)(GodotDictionary dictionary, string name, T defaultValue)
{
    auto value = dictionary.get(name);
    return value is null ? defaultValue : as!T(*value, name);
}

private long propertyLong(GodotDictionary dictionary, string name, long defaultValue = 0)
{
    auto value = dictionary.get(name);
    return value is null ? defaultValue : asLong(*value, name);
}

private string propertyString(GodotDictionary dictionary, string name, string defaultValue = "")
{
    auto value = dictionary.get(name);
    return value is null ? defaultValue : asString(*value, name);
}

private ubyte[] propertyBytes(GodotDictionary dictionary, string name)
{
    auto value = dictionary.get(name);
    if(value is null)
        return null;

    if(value.type !is typeid(ubyte[]))
        throw new PukanException(name ~ ": expected PackedByteArray");

    return cast(ubyte[]) value.get!(ubyte[]);
}

GodotArraySurface[] decodeArrayMesh(GodotVariant surfacesValue)
{
    if(surfacesValue.type is typeid(GodotNil))
        return null;

    auto surfaces = asArray(surfacesValue, "_surfaces");
    GodotArraySurface[] result;
    result.reserve(surfaces.length);

    foreach(ref surfaceValue; surfaces.items)
    {
        auto surface = asDictionary(surfaceValue, "surface");

        const format = propertyLong(surface, "format");
        const surfaceVersion = cast(int) ((format >> formatVersionShift) & formatVersionMask);
        if(surfaceVersion != 1)
            throw new PukanException("unsupported mesh surface format version " ~ surfaceVersion.to!string);

        if((format & flagCompressAttributes) != 0)
            throw new PukanException("attribute-compressed mesh surfaces are not supported yet");

        if((format & flag2dVertices) != 0)
            throw new PukanException("2D mesh surfaces are not supported");

        if((format & (arrayCustom0 | (arrayCustom0 << 1) | (arrayCustom0 << 2) | (arrayCustom0 << 3))) != 0)
            throw new PukanException("custom vertex channels are not supported");

        if((format & arrayVertex) == 0)
            throw new PukanException("mesh surface has no vertices");

        const vertexCount = cast(size_t) propertyLong(surface, "vertex_count");
        const indexCount = cast(size_t) propertyLong(surface, "index_count");
        const primitive = cast(GodotPrimitive) propertyLong(surface, "primitive");

        GodotArraySurface decoded;
        decoded.primitive = primitive;
        decoded.name = propertyString(surface, "name");
        decoded.aabb = propertyAs!GodotAabb(surface, "aabb", GodotAabb.init);
        decoded.geometry.aabb = decoded.aabb.toBox();

        if(auto material = property(surface, "material"))
        {
            decoded.material = asObjectRef(*material, "material");
            decoded.hasMaterial = true;
        }

        const vertexData = propertyBytes(surface, "vertex_data");
        const attributeData = propertyBytes(surface, "attribute_data");
        const skinData = propertyBytes(surface, "skin_data");
        const indexData = propertyBytes(surface, "index_data");

        const hasNormal = (format & arrayNormal) != 0;
        const hasTangent = (format & arrayTangent) != 0;
        const hasColor = (format & arrayColor) != 0;
        const hasUv = (format & arrayTexUv) != 0;
        const hasUv2 = (format & arrayTexUv2) != 0;
        const hasBones = (format & arrayBones) != 0;
        const hasWeights = (format & arrayWeights) != 0;

        const vertexStride = 3 * float.sizeof;
        const normalBase = vertexCount * vertexStride;
        const normalStride = (hasNormal ? 4 : 0) + (hasTangent ? 4 : 0);
        const attributeStride = (hasColor ? 4 : 0) + (hasUv ? 8 : 0) + (hasUv2 ? 8 : 0);
        const boneSize = (format & flag8BoneWeights) ? 16 : 8;
        const skinStride = (hasBones ? boneSize : 0) + (hasWeights ? boneSize : 0);

        const colorOffset = 0;
        const uvOffset = hasColor ? 4 : 0;
        const uv2Offset = uvOffset + (hasUv ? 8 : 0);
        const bonesOffset = 0;
        const weightsOffset = hasBones ? boneSize : 0;

        if(vertexData.length < normalBase + vertexCount * normalStride)
            throw new PukanException("mesh vertex data is too short");

        if(attributeData.length < vertexCount * attributeStride)
            throw new PukanException("mesh attribute data is too short");

        if((hasBones || hasWeights) && skinData.length < vertexCount * skinStride)
            throw new PukanException("mesh skin data is too short");

        decoded.geometry.positions.length = vertexCount;
        decoded.geometry.normals.length = hasNormal ? vertexCount : 0;
        decoded.geometry.tangents.length = hasTangent ? vertexCount : 0;
        decoded.geometry.colors.length = hasColor ? vertexCount : 0;
        decoded.geometry.texCoords.length = hasUv ? vertexCount : 0;
        decoded.geometry.joints.length = hasBones ? vertexCount : 0;
        decoded.geometry.weights.length = hasWeights ? vertexCount : 0;

        foreach(i; 0 .. vertexCount)
        {
            const vertex = vertexData.ptr + i * vertexStride;
            const position = cast(const float*) vertex;
            decoded.geometry.positions[i] = Vector3f(position[0], position[1], position[2]);

            if(hasNormal)
            {
                const packed = *cast(const uint*) (vertexData.ptr + normalBase + i * normalStride);
                const normal = octahedronDecode(Vector2f(
                    (packed & 0xFFFF) / 65535.0f,
                    ((packed >> 16) & 0xFFFF) / 65535.0f,
                ));
                decoded.geometry.normals[i] = normal;
            }

            if(hasTangent)
            {
                const packed = *cast(const uint*) (vertexData.ptr + normalBase + i * normalStride + (hasNormal ? 4 : 0));
                float sign;
                const tangent = octahedronTangentDecode(Vector2f(
                    (packed & 0xFFFF) / 65535.0f,
                    ((packed >> 16) & 0xFFFF) / 65535.0f,
                ), sign);
                decoded.geometry.tangents[i] = Vector4f(tangent.x, tangent.y, tangent.z, sign);
            }

            const attribute = attributeData.ptr + i * attributeStride;

            if(hasColor)
            {
                const c = attribute + colorOffset;
                decoded.geometry.colors[i] =
                    cast(uint) c[0] |
                    (cast(uint) c[1] << 8) |
                    (cast(uint) c[2] << 16) |
                    (cast(uint) c[3] << 24);
            }

            if(hasUv)
            {
                const uv = cast(const float*) (attribute + uvOffset);
                decoded.geometry.texCoords[i] = Vector2f(uv[0], uv[1]);
            }

            if(hasBones || hasWeights)
            {
                const skin = skinData.ptr + i * skinStride;

                if(hasBones)
                {
                    const bones = cast(const ushort*) (skin + bonesOffset);
                    decoded.geometry.joints[i] = Vector4us(bones[0], bones[1], bones[2], bones[3]);
                }

                if(hasWeights)
                {
                    const weights = cast(const ushort*) (skin + weightsOffset);
                    decoded.geometry.weights[i] = Vector4f(
                        weights[0] / 65535.0f,
                        weights[1] / 65535.0f,
                        weights[2] / 65535.0f,
                        weights[3] / 65535.0f,
                    );
                }
            }
        }

        if(indexCount)
        {
            if(indexData.length % indexCount != 0)
                throw new PukanException("mesh index data does not match index count");

            const indexSize = indexData.length / indexCount;
            if(indexSize != 2 && indexSize != 4)
                throw new PukanException("unsupported mesh index size " ~ indexSize.to!string);

            decoded.geometry.indices.length = indexCount;

            foreach(i; 0 .. indexCount)
            {
                if(indexSize == 2)
                    decoded.geometry.indices[i] = (cast(const ushort*) indexData.ptr)[i];
                else
                    decoded.geometry.indices[i] = *cast(const uint*) (indexData.ptr + i * 4);
            }
        }

        result ~= decoded;
    }

    return result;
}

private Vector3f octahedronDecode(Vector2f encoded)
{
    import std.algorithm: max, min;

    const f = Vector2f(encoded.x * 2.0f - 1.0f, encoded.y * 2.0f - 1.0f);
    auto n = Vector3f(f.x, f.y, 1.0f - abs(f.x) - abs(f.y));
    const t = min(max(-n.z, 0.0f), 1.0f);

    n.x += n.x >= 0 ? -t : t;
    n.y += n.y >= 0 ? -t : t;

    return n.normalized;
}

private Vector3f octahedronTangentDecode(Vector2f encoded, out float sign)
{
    auto compressed = Vector2f(encoded.x, encoded.y * 2.0f - 1.0f);
    sign = compressed.y >= 0 ? 1.0f : -1.0f;
    compressed.y = abs(compressed.y);

    return octahedronDecode(compressed);
}

unittest
{
    import pukan.godot_scene.text: GodotTextResource, parseGodotTextFile;

    auto document = parseGodotTextFile(fixturePath("generated/procedural.tscn"));

    GodotTextResource* mesh;
    foreach(ref resource; document.subResources)
        if(resource.type == "ArrayMesh")
            mesh = &resource;
    assert(mesh !is null);

    const surfaces = decodeArrayMesh(mesh.properties["_surfaces"]);
    assert(surfaces.length == 2);
    assert(surfaces[0].primitive == GodotPrimitive.triangles);
    assert(surfaces[0].geometry.positions.length == 4);
    assert(surfaces[0].geometry.normals.length == 4);
    assert(surfaces[0].geometry.tangents.length == 4);
    assert(surfaces[0].geometry.colors.length == 4);
    assert(surfaces[0].geometry.texCoords.length == 4);
    assert(surfaces[0].geometry.indices.length == 6);

    assert(surfaces[0].geometry.positions[0] == Vector3f(-1, 0, -1));
    assert(surfaces[0].geometry.positions[3] == Vector3f(1, 0, 1));
    assert(surfaces[0].geometry.normals[0].y > 0.99f);
    assert(surfaces[0].geometry.tangents[0].x > 0.99f);
    assert(surfaces[0].geometry.tangents[0].w > 0);
    assert(surfaces[0].geometry.colors[0] == 0xFF0000FF);
    assert(surfaces[0].geometry.texCoords[3] == Vector2f(1, 1));
    assert(surfaces[0].geometry.indices == [0u, 1u, 2u, 1u, 3u, 2u]);

    assert(surfaces[1].geometry.positions.length == 3);
    assert(surfaces[1].geometry.colors.length == 0);
    assert(surfaces[1].geometry.indices == [0u, 2u, 1u]);
}

private string fixturePath(string relative)
{
    import std.path: buildPath, dirName;
    return buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "demo", "assets", "godot_samples", relative);
}
