module pukan.godot_scene.mesh;

import dlib.math: Vector2f, Vector3f, Vector4f;
import pukan.exceptions: PukanException;
import pukan.godot_scene.value;
import pukan.pbr.mesh: MeshGeometry, Vector4us;
import std.conv: to;
import std.math: PI, abs, cos, sin;

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
        if(surfaceVersion > 1)
            throw new PukanException("unsupported mesh surface format version " ~ surfaceVersion.to!string);

        // Version 1 interleaves positions, normals and tangents per vertex
        const version1 = surfaceVersion == 0;

        const compressed = (format & flagCompressAttributes) != 0;

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

        if(compressed && hasTangent && !hasNormal)
            throw new PukanException("compressed mesh tangents require normals");

        const vertexSize = compressed ? 4 * ushort.sizeof : 3 * float.sizeof;
        const normalSize = hasNormal ? 4 : 0;
        const tangentSize = compressed ? 0 : (hasTangent ? 4 : 0);
        const positionStride = version1 ? vertexSize + normalSize + tangentSize : vertexSize;
        const normalBase = version1 ? 0 : vertexCount * vertexSize;
        const normalStride = version1 ? positionStride : normalSize + tangentSize;
        const normalOffset = version1 ? vertexSize : 0;
        const tangentOffset = normalOffset + normalSize;
        const uvSize = compressed ? 4 : 8;
        const attributeStride = (hasColor ? 4 : 0) + (hasUv ? uvSize : 0) + (hasUv2 ? uvSize : 0);
        const boneSize = (format & flag8BoneWeights) ? 16 : 8;
        const skinStride = (hasBones ? boneSize : 0) + (hasWeights ? boneSize : 0);

        const colorOffset = 0;
        const uvOffset = hasColor ? 4 : 0;
        const uv2Offset = uvOffset + (hasUv ? uvSize : 0);
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

        const uvScale = propertyAs!Vector4f(surface, "uv_scale", Vector4f(0, 0, 0, 0));

        foreach(i; 0 .. vertexCount)
        {
            const vertex = vertexData.ptr + i * positionStride;

            if(compressed)
            {
                const packed = cast(const ushort*) vertex;
                const normalized = Vector3f(
                    packed[0] / 65535.0f,
                    packed[1] / 65535.0f,
                    packed[2] / 65535.0f,
                );

                decoded.geometry.positions[i] = Vector3f(
                    decoded.aabb.position.x + normalized.x * decoded.aabb.size.x,
                    decoded.aabb.position.y + normalized.y * decoded.aabb.size.y,
                    decoded.aabb.position.z + normalized.z * decoded.aabb.size.z,
                );
            }
            else
            {
                const position = cast(const float*) vertex;
                decoded.geometry.positions[i] = Vector3f(position[0], position[1], position[2]);
            }

            Vector3f normal;

            if(hasNormal)
            {
                const packed = *cast(const uint*) (vertexData.ptr + normalBase + i * normalStride + normalOffset);
                normal = octahedronDecode(Vector2f(
                    (packed & 0xFFFF) / 65535.0f,
                    ((packed >> 16) & 0xFFFF) / 65535.0f,
                ));
                decoded.geometry.normals[i] = normal;
            }

            if(hasTangent)
            {
                if(compressed)
                {
                    const positionPacked = cast(const ushort*) vertex;
                    const angle01 = positionPacked[3] / 65535.0f;
                    const sign = angle01 > 0.5f ? 1.0f : -1.0f;
                    const angle = abs(angle01 * 2.0f - 1.0f) * PI;
                    const c = cos(angle);
                    const s = sin(angle);
                    const omc = 1.0f - c;
                    const tangent = Vector3f(
                        omc * normal.x * normal.x + c,
                        omc * normal.x * normal.y - s * normal.z,
                        omc * normal.x * normal.z + s * normal.y,
                    );
                    decoded.geometry.tangents[i] = Vector4f(tangent.x, tangent.y, tangent.z, sign);
                }
                else
                {
                    const packed = *cast(const uint*) (vertexData.ptr + normalBase + i * normalStride + tangentOffset);
                    float sign;
                    const tangent = octahedronTangentDecode(Vector2f(
                        (packed & 0xFFFF) / 65535.0f,
                        ((packed >> 16) & 0xFFFF) / 65535.0f,
                    ), sign);
                    decoded.geometry.tangents[i] = Vector4f(tangent.x, tangent.y, tangent.z, sign);
                }
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
                if(compressed)
                {
                    const packed = cast(const ushort*) (attribute + uvOffset);
                    auto uv = Vector2f(packed[0] / 65535.0f, packed[1] / 65535.0f);

                    if(uvScale.x != 0.0f || uvScale.y != 0.0f)
                        uv = Vector2f((uv.x - 0.5f) * uvScale.x, (uv.y - 0.5f) * uvScale.y);

                    decoded.geometry.texCoords[i] = uv;
                }
                else
                {
                    const uv = cast(const float*) (attribute + uvOffset);
                    decoded.geometry.texCoords[i] = Vector2f(uv[0], uv[1]);
                }
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

unittest
{
    import pukan.godot_scene.text: parseGodotTextFile;
    import std.path: buildPath, dirName;

    const path = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "demo", "assets",
        "godot_samples", "generated", "compressed_array_mesh.tres");
    auto document = parseGodotTextFile(path);
    auto surfaces = decodeArrayMesh(document.resourceProperties["_surfaces"]);

    assert(surfaces.length == 1);
    assert(surfaces[0].geometry.positions.length == 36);
    assert(surfaces[0].geometry.normals.length == 36);
    assert(surfaces[0].geometry.tangents.length == 36);
    assert(surfaces[0].geometry.texCoords.length == 36);
    assert(surfaces[0].geometry.indices.length == 36);

    foreach(position; surfaces[0].geometry.positions)
    {
        assert(position.x >= -1.001f && position.x <= 1.001f);
        assert(position.y >= -1.001f && position.y <= 1.001f);
        assert(position.z >= -1.001f && position.z <= 1.001f);
    }

    assert(surfaces[0].geometry.texCoords[0].x >= -1.001f);
    assert(surfaces[0].geometry.texCoords[0].x <= 1.001f);
}

unittest
{
    import pukan.godot_scene.text: parseGodotTextFile;
    import std.path: buildPath, dirName;

    const path = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "demo", "assets",
        "godot_samples", "generated", "compressed_array_mesh.tres");
    auto document = parseGodotTextFile(path);
    const surfacesValue = document.resourceProperties["_surfaces"];
    const surfaces = asArray(surfacesValue);
    auto original = asDictionary(surfaces[0], "surface");

    const format = asLong(*original.get("format"), "format");
    const vertexCount = cast(size_t) asLong(*original.get("vertex_count"), "vertex_count");
    const vertexData = propertyBytes(original, "vertex_data");

    // Version 2 keeps positions in one block and normals in another.
    assert((format & (1L << 29)) != 0);

    ubyte[] interleaved;
    interleaved.length = vertexCount * 12;

    foreach(i; 0 .. vertexCount)
    {
        interleaved[i * 12 .. i * 12 + 8] = vertexData[i * 8 .. i * 8 + 8];

        const normal = vertexCount * 8 + i * 4;
        interleaved[i * 12 + 8 .. i * 12 + 12] = vertexData[normal .. normal + 4];
    }

    auto version1Surface = new GodotDictionary;
    version1Surface.keys = original.keys.dup;
    version1Surface.values = original.values.dup;
    version1Surface.set("format", GodotVariant(format & ~(0xFFL << 35)));
    version1Surface.set("vertex_data", GodotVariant(interleaved));

    auto version1Surfaces = new GodotArray([GodotVariant(version1Surface)]);
    const version1 = decodeArrayMesh(GodotVariant(version1Surfaces));
    const version2 = decodeArrayMesh(surfacesValue);

    assert(version1.length == 1);
    assert(version2.length == 1);
    assert(version1[0].geometry.positions == version2[0].geometry.positions);
    assert(version1[0].geometry.normals == version2[0].geometry.normals);
    assert(version1[0].geometry.tangents == version2[0].geometry.tangents);
    assert(version1[0].geometry.texCoords == version2[0].geometry.texCoords);
}
