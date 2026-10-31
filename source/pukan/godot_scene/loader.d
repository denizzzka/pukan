module pukan.godot_scene.loader;

import dlib.math: Matrix4x4f, Quaternionf, Vector2f, Vector3f, Vector4f, degtorad, scaleMatrix, translationMatrix;
import material_bindings;
import pukan.compressed_texture: CompressedFamily, familySupported, formatSupported;
import pukan.exceptions: PukanException;
import pukan.godot_scene.binary: parseGodotResourceData;
import pukan.godot_scene.ctex: GodotCtexImage, isTwoChannelNormal, loadCtex;
import pukan.godot_scene.material: GodotMaterialData, readGodotMaterial;
import pukan.godot_scene.paths: normalizeResourcePath;
import pukan.godot_scene.remap: resolveGodotPath;
import pukan.godot_scene.source: DirectorySource, GodotSource;
import pukan.godot_scene.mesh: GodotArraySurface, GodotPrimitive, decodeArrayMesh;
import pukan.godot_scene.primitives: decodePrimitiveMesh, isPrimitiveMesh;
import pukan.godot_scene.scene: GodotBone, GodotCamera, GodotLight, GodotLightKind, GodotNode, GodotScene, GodotSkin, GodotSkeleton;
import pukan.godot_scene.text: GodotTextDocument, GodotTextExternal, GodotTextNode, GodotTextResource, parseGodotTextFile;
import pukan.godot_scene.value;
import pukan.gltf: GlTF;
import pukan.gltf.factory: GltfFactory;
import pukan.material: AlphaMode, Material, MaterialFlag, MaterialMode;
import pukan.misc: linearFormat, loadImageFromMemory;
import pukan.pbr.accessor: BufAccess, BufferPieceOnGPU;
import pukan.pbr.factory: PbrFactory;
import pukan.pbr.mesh: IndicesDescr, MeshStreams, PbrGeometry, PbrMesh, Vector4us, applyWinding;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.image: identityComponentMapping, loadImageToMemory, loadImageWithMips;
import pukan.vulkan.pipelines: DescriptorAllocator;
import pukan.vulkan.textures: Texture, requiredAnisotropy;
import std.algorithm: canFind, endsWith;
import std.conv: to;
import std.file: exists, getcwd;
import std.path: buildNormalizedPath, buildPath, dirName, extension, isAbsolute, relativePath;
import std.algorithm: startsWith;
import std.string: replace, split, toLower;

/// Options for loading one Godot scene
struct GodotLoadOptions
{
    /// Overrides the directory found by walking up to `project.godot`
    string projectRoot;
    /// Scene keys already being instantiated, to break cycles
    string[] loadStack;
    /// Properties the parent scene overrides on this scene's root
    GodotVariant[string] rootOverrides;
    bool hasRootOverrides;
}

private final class GodotProject
{
    GodotSource source;
    string root;
    LogicalDevice device;
    GodotTextDocument[string] documents;

    this(GodotSource source, string root, LogicalDevice device = null)
    {
        this.source = source;
        this.root = root;
        this.device = device;
    }

    string key(string path) const
    {
        return "res://" ~ normalizeResourcePath(path);
    }

    /// Stored path after exported `.remap` and source `.import` chains
    string resolve(string key)
    {
        return resolveGodotPath(source, key, &supportedRemap);
    }

    private bool supportedRemap(string feature)
    {
        if(device is null)
            return true;

        final switch(feature)
        {
            case "s3tc":
            case "bptc":
                return familySupported(device, CompressedFamily.bc);

            case "etc2":
                return familySupported(device, CompressedFamily.etc2);

            case "astc":
                return familySupported(device, CompressedFamily.astc);

            case "mobile":
                return familySupported(device, CompressedFamily.etc2) ||
                    familySupported(device, CompressedFamily.astc);
        }
    }

    /// Filesystem path for loaders that take a filename, null for packs
    string physical(string key)
    {
        if(auto directory = cast(DirectorySource) source)
            return directory.physical(resolve(key));

        return null;
    }

    GodotTextDocument document(string key)
    {
        key = resolve(key);

        if(auto cached = key in documents)
            return *cached;

        auto document = parseGodotResourceData(source.read(key), key);
        documents[key] = document;
        return document;
    }
}

private enum raAsRgMapping = VkComponentMapping(
    r: VK_COMPONENT_SWIZZLE_R,
    g: VK_COMPONENT_SWIZZLE_A,
    b: VK_COMPONENT_SWIZZLE_ZERO,
    a: VK_COMPONENT_SWIZZLE_ONE,
);

/// One occupied cell of a GridMap, decoded from its packed data array
struct GridMapCell
{
    short x, y, z;
    uint item;
    uint rotation;
}

/// The packed array holds the key low half, the key high half and the cell
GridMapCell[] decodeGridMapCells(const(int)[] packed)
{
    if(packed.length % 3 != 0)
        throw new PukanException("GridMap data is not a list of cell triples");

    GridMapCell[] result;
    result.reserve(packed.length / 3);

    foreach(i; 0 .. packed.length / 3)
    {
        const low = cast(uint) packed[i * 3];
        const high = cast(uint) packed[i * 3 + 1];
        const cell = cast(uint) packed[i * 3 + 2];

        result ~= GridMapCell(
            cast(short) (low & 0xFFFF),
            cast(short) ((low >> 16) & 0xFFFF),
            cast(short) (high & 0xFFFF),
            cell & 0xFFFF,
            (cell >> 16) & 0x1F,
        );
    }

    return result;
}

unittest
{
    const cells = decodeGridMapCells([
        3, 0, cast(int) (8 | (16 << 16)),
        cast(int) 0x0000FFFE, 7, cast(int) 15,
    ]);

    assert(cells.length == 2);
    assert(cells[0].x == 3 && cells[0].y == 0 && cells[0].z == 0);
    assert(cells[0].item == 8 && cells[0].rotation == 16);
    assert(cells[1].x == -2 && cells[1].y == 0 && cells[1].z == 7);
    assert(cells[1].item == 15 && cells[1].rotation == 0);
}

/// Godot's 24 orthogonal cell orientations, each written as basis rows
Matrix4x4f gridMapRotation(uint rotation)
{
    static immutable int[9][24] bases = [
        [ 1,  0,  0,  0,  1,  0,  0,  0,  1],
        [ 0, -1,  0,  1,  0,  0,  0,  0,  1],
        [-1,  0,  0,  0, -1,  0,  0,  0,  1],
        [ 0,  1,  0, -1,  0,  0,  0,  0,  1],
        [ 1,  0,  0,  0,  0, -1,  0,  1,  0],
        [ 0,  0,  1,  1,  0,  0,  0,  1,  0],
        [-1,  0,  0,  0,  0,  1,  0,  1,  0],
        [ 0,  0, -1, -1,  0,  0,  0,  1,  0],
        [ 1,  0,  0,  0, -1,  0,  0,  0, -1],
        [ 0,  1,  0,  1,  0,  0,  0,  0, -1],
        [-1,  0,  0,  0,  1,  0,  0,  0, -1],
        [ 0, -1,  0, -1,  0,  0,  0,  0, -1],
        [ 1,  0,  0,  0,  0,  1,  0, -1,  0],
        [ 0,  0, -1,  1,  0,  0,  0, -1,  0],
        [-1,  0,  0,  0,  0, -1,  0, -1,  0],
        [ 0,  0,  1, -1,  0,  0,  0, -1,  0],
        [ 0,  0,  1,  0,  1,  0, -1,  0,  0],
        [ 0, -1,  0,  0,  0,  1, -1,  0,  0],
        [ 0,  0, -1,  0, -1,  0, -1,  0,  0],
        [ 0,  1,  0,  0,  0, -1, -1,  0,  0],
        [ 0,  0,  1,  0, -1,  0,  1,  0,  0],
        [ 0,  1,  0,  0,  0,  1,  1,  0,  0],
        [ 0,  0, -1,  0,  1,  0,  1,  0,  0],
        [ 0, -1,  0,  0,  0, -1,  1,  0,  0],
    ];

    Matrix4x4f result = Matrix4x4f.identity;

    if(rotation >= bases.length)
        return result;

    const b = bases[rotation];
    result.a11 = b[0]; result.a12 = b[1]; result.a13 = b[2];
    result.a21 = b[3]; result.a22 = b[4]; result.a23 = b[5];
    result.a31 = b[6]; result.a32 = b[7]; result.a33 = b[8];
    return result;
}

unittest
{
    const identity = gridMapRotation(0);
    assert(identity.a11 == 1 && identity.a22 == 1 && identity.a33 == 1);

    const turned = gridMapRotation(16);
    assert(turned.a13 == 1 && turned.a31 == -1 && turned.a22 == 1);
}

/// Godot's BaseMaterial3D texture_filter values, as a sampler pair
private struct SamplerKey
{
    uint filter;
    bool repeat;
}

/// Sampler state of a Godot material; `anisotropic` is false when unsupported
private VkSamplerCreateInfo samplerState(uint filter, bool repeat, bool anisotropic)
{
    VkSamplerCreateInfo info = {
        sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        magFilter: VK_FILTER_LINEAR,
        minFilter: VK_FILTER_LINEAR,
        mipmapMode: VK_SAMPLER_MIPMAP_MODE_LINEAR,
        addressModeU: repeat ? VK_SAMPLER_ADDRESS_MODE_REPEAT : VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        addressModeV: repeat ? VK_SAMPLER_ADDRESS_MODE_REPEAT : VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        addressModeW: repeat ? VK_SAMPLER_ADDRESS_MODE_REPEAT : VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        anisotropyEnable: anisotropic ? VK_TRUE : VK_FALSE,
        maxAnisotropy: anisotropic ? requiredAnisotropy : 0.0f,
        compareEnable: VK_FALSE,
        compareOp: VK_COMPARE_OP_ALWAYS,
        borderColor: VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        unnormalizedCoordinates: VK_FALSE,
        // Without mipmaps the base level alone is sampled
        maxLod: 0.0f,
    };

    switch(filter)
    {
        case 0:
            info.magFilter = VK_FILTER_NEAREST;
            info.minFilter = VK_FILTER_NEAREST;
            break;

        case 1:
            break;

        case 2, 4:
            info.magFilter = VK_FILTER_NEAREST;
            info.minFilter = VK_FILTER_NEAREST;
            info.maxLod = VK_LOD_CLAMP_NONE;
            break;

        default:
            info.maxLod = VK_LOD_CLAMP_NONE;
            break;
    }

    return info;
}

unittest
{
    const nearest = samplerState(0, false, false);
    assert(nearest.magFilter == VK_FILTER_NEAREST);
    assert(nearest.minFilter == VK_FILTER_NEAREST);
    assert(nearest.addressModeU == VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE);
    assert(nearest.maxLod == 0.0f);
    assert(nearest.anisotropyEnable == VK_FALSE);

    const linear = samplerState(3, true, false);
    assert(linear.magFilter == VK_FILTER_LINEAR);
    assert(linear.addressModeV == VK_SAMPLER_ADDRESS_MODE_REPEAT);
    assert(linear.maxLod == VK_LOD_CLAMP_NONE);

    const anisotropic = samplerState(4, true, true);
    assert(anisotropic.anisotropyEnable == VK_TRUE);
    assert(anisotropic.maxAnisotropy == requiredAnisotropy);
}

private final class GodotLoader
{
    LogicalDevice device;
    PbrFactory pbr;
    GltfFactory gltfFactory;
    GodotLoadOptions options;
    DescriptorAllocator allocator;

    CommandPool commandPool;
    VkCommandBuffer commandBuffer;

    GodotProject project;
    string scenePath;
    bool gltfImportedScene;

    BufferPieceOnGPU[] gpuBuffs;
    PbrMesh[] meshes;
    PbrGeometry[string] geometryCache;
    Texture[] textures;
    Texture[string] textureCache;
    VkSampler[SamplerKey] samplerCache;
    VkSampler[] samplers;
    DrawableByVulkan[] instances;
    GodotSkin[] skins;
    VkDescriptorImageInfo fakeTextureInfo;

    size_t skippedNodes;
    size_t skippedResources;
    size_t[string] skippedNodeTypes;
    size_t[string] skippedResourceTypes;

    this(LogicalDevice device, PbrFactory pbr, GltfFactory gltfFactory, GodotLoadOptions options)
    {
        this.device = device;
        this.pbr = pbr;
        this.gltfFactory = gltfFactory;
        this.options = options;
        this.allocator = pbr.createAllocator();

        fakeTextureInfo = VkDescriptorImageInfo(
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            imageView: pbr.resources.fakeTexture.imageView,
            sampler: pbr.resources.fakeTexture.sampler,
        );
    }

    /// Shared sampler of a material filter and wrap mode
    private VkSampler samplerFor(uint filter, bool repeat)
    {
        const key = SamplerKey(filter, repeat);

        if(auto cached = key in samplerCache)
            return *cached;

        const ctx = device.deviceContext();
        const anisotropic = ctx.enabled.samplerAnisotropy == VK_TRUE
            && ctx.properties.limits.maxSamplerAnisotropy >= requiredAnisotropy;

        auto info = samplerState(filter, repeat, anisotropic);
        VkSampler sampler;
        vkCall(device.device, &info, device.alloc, &sampler);

        samplerCache[key] = sampler;
        samplers ~= sampler;

        return sampler;
    }

    GodotScene run(string filename)
    {
        const physicalPath = absolutePath(filename);
        const rootDir = options.projectRoot.length
            ? buildNormalizedPath(options.projectRoot)
            : findProjectRoot(physicalPath);
        const sceneKey = "res://" ~ relativePath(physicalPath, rootDir).replace("\\", "/");

        return run(new DirectorySource(rootDir), sceneKey, rootDir);
    }

    GodotScene run(GodotSource source, string sceneKey, string rootDir)
    {
        scenePath = sceneKey;
        gltfImportedScene = sceneKey.canFind(".godot/imported/") &&
            (sceneKey.canFind(".glb-") || sceneKey.canFind(".gltf-"));
        project = new GodotProject(source, rootDir, device);

        commandPool = device.createCommandPool();
        auto buffers = commandPool.allocateBuffers(1);
        commandBuffer = buffers[0];

        scope(exit)
        {
            commandPool.freeBuffers(buffers);
            destroy(commandPool);
        }

        auto document = project.document(scenePath);
        auto root = buildTree(document);

        GodotLight[] lights;
        GodotCamera camera;
        bool hasCamera;
        collectSceneNodes(root, Matrix4x4f.identity(), lights, camera, hasCamera);

        // Godot stores clockwise triangles in its meshes and primitives
        applyWinding!(GodotNode, GodotNode)(root, Matrix4x4f.identity(), false, node => node.local);

        auto scene = new GodotScene(
            pbr.godotPipelines,
            device,
            pbr.resources.materials,
            root,
            meshes,
            gpuBuffs,
            textures,
            samplers,
            instances,
            skins,
            root.name,
        );
        scene.skippedNodes = skippedNodes;
        scene.skippedResources = skippedResources;
        scene.skippedNodeTypes = skippedNodeTypes;
        scene.skippedResourceTypes = skippedResourceTypes;
        scene.geometryCount = geometryCache.length;
        scene.lights = lights;
        scene.camera = camera;
        scene.hasCamera = hasCamera;
        return scene;
    }

    private static string absolutePath(string path)
    {
        return isAbsolute(path)
            ? buildNormalizedPath(path)
            : buildNormalizedPath(buildPath(getcwd(), path));
    }

    private static string findProjectRoot(string scenePath)
    {
        auto dir = dirName(scenePath);

        while(dir.length)
        {
            if(exists(buildPath(dir, "project.godot")))
                return dir;

            const parent = dirName(dir);
            if(parent == dir)
                break;
            dir = parent;
        }

        return dirName(scenePath);
    }

    private static void collectSceneNodes(
        GodotNode node,
        Matrix4x4f parent,
        ref GodotLight[] lights,
        ref GodotCamera camera,
        ref bool hasCamera,
    )
    {
        if(!node.visible)
            return;

        const world = parent * node.local;

        if(node.hasLight)
        {
            GodotLight light = node.light;
            light.position = Vector3f(world.a14, world.a24, world.a34);

            const zAxis = Vector3f(world.a13, world.a23, world.a33).normalized;
            light.direction = light.kind == GodotLightKind.directional ? zAxis : -zAxis;
            lights ~= light;
        }

        if(node.hasCamera && !hasCamera)
        {
            camera.view = world.inverse;
            camera.fov = node.camera.fov;
            camera.nearPlane = node.camera.nearPlane;
            camera.farPlane = node.camera.farPlane;
            hasCamera = true;
        }

        foreach(child; node.children)
            collectSceneNodes(child, world, lights, camera, hasCamera);
    }

    private GodotNode buildTree(ref GodotTextDocument document)
    {
        size_t rootIndex = size_t.max;
        foreach(i, ref section; document.nodes)
            if(section.parent.length == 0)
            {
                rootIndex = i;
                break;
            }

        if(rootIndex == size_t.max)
            throw new PukanException(scenePath ~ ": scene has no root node");

        auto root = createNode(document, document.nodes[rootIndex]);

        GodotNode[string] byPath;
        byPath["."] = root;
        byPath[root.name] = root;

        foreach(i, ref section; document.nodes)
        {
            if(i == rootIndex)
                continue;

            const parentPath = section.parent;
            auto parent = parentPath in byPath;

            if(parent is null)
            {
                ++skippedNodes;
                continue;
            }

            auto node = createNode(document, section, *parent);
            (*parent).addChild(node);
            byPath[parentPath == "." ? section.name : parentPath ~ "/" ~ section.name] = node;
        }

        return root;
    }

    private static double propertyDouble(in GodotVariant[string] properties, string name, double defaultValue)
    {
        auto value = name in properties;
        return value is null ? defaultValue : asDouble(*value, name);
    }

    private static long propertyLong(in GodotVariant[string] properties, string name, long defaultValue)
    {
        auto value = name in properties;
        return value is null ? defaultValue : asLong(*value, name);
    }

    private static bool propertyBool(in GodotVariant[string] properties, string name, bool defaultValue)
    {
        auto value = name in properties;
        return value is null ? defaultValue : asBool(*value, name);
    }

    private static GodotColor propertyColor(in GodotVariant[string] properties, string name, GodotColor defaultValue)
    {
        auto value = name in properties;
        return value is null ? defaultValue : as!(GodotColor)(*value, name);
    }

    private static GodotSkeleton parseSkeleton(in GodotVariant[string] properties)
    {
        import std.algorithm: max;

        size_t boneCount;

        foreach(key; properties.keys)
        {
            if(!key.startsWith("bones/"))
                continue;

            const parts = key.split("/");
            if(parts.length < 3)
                continue;

            const index = parts[1].to!size_t;
            boneCount = max(boneCount, index + 1);
        }

        GodotSkeleton result;
        result.bones.length = boneCount;
        result.globalPoses.length = boneCount;

        bool[] hasPosition;
        bool[] hasRotation;
        bool[] hasScale;
        Vector3f[] positions;
        Quaternionf[] rotations;
        Vector3f[] scales;
        hasPosition.length = hasRotation.length = hasScale.length = boneCount;
        positions.length = rotations.length = scales.length = boneCount;

        foreach(key, ref value; properties)
        {
            if(!key.startsWith("bones/"))
                continue;

            const parts = key.split("/");
            if(parts.length < 3)
                continue;

            const index = parts[1].to!size_t;
            if(index >= boneCount)
                continue;

            ref bone = result.bones[index];

            switch(parts[2])
            {
                case "name":
                    bone.name = asString(value, key);
                    break;

                case "parent":
                    bone.parent = cast(int) asLong(value, key);
                    break;

                case "rest":
                    bone.rest = as!(GodotTransform3D)(value, key).toMatrix;
                    break;

                case "enabled":
                    bone.enabled = asBool(value, key);
                    break;

                case "position":
                    positions[index] = as!(Vector3f)(value, key);
                    hasPosition[index] = true;
                    break;

                case "rotation":
                    rotations[index] = as!(Quaternionf)(value, key);
                    hasRotation[index] = true;
                    break;

                case "scale":
                    scales[index] = as!(Vector3f)(value, key);
                    hasScale[index] = true;
                    break;

                default:
                    break;
            }
        }

        bool[] done;
        done.length = boneCount;

        Matrix4x4f resolve(size_t index, size_t depth)
        {
            if(done[index])
                return result.globalPoses[index];

            if(depth > boneCount)
                return result.bones[index].local;

            ref GodotBone bone = result.bones[index];
            bone.local = bone.rest;

            if(hasPosition[index] || hasRotation[index] || hasScale[index])
            {
                Matrix4x4f local = Matrix4x4f.identity();

                if(hasPosition[index])
                    local *= translationMatrix(positions[index]);
                if(hasRotation[index])
                    local *= rotations[index].toMatrix4x4;
                if(hasScale[index])
                    local *= scaleMatrix(scales[index]);

                bone.local = bone.enabled ? local : bone.rest;
            }

            Matrix4x4f global = bone.local;

            if(bone.parent >= 0 && cast(size_t) bone.parent < boneCount)
                global = resolve(cast(size_t) bone.parent, depth + 1) * global;

            result.globalPoses[index] = global;
            done[index] = true;
            return global;
        }

        foreach(i; 0 .. boneCount)
            resolve(i, 0);

        return result;
    }

    private GodotNode createNode(ref GodotTextDocument document, ref GodotTextNode section, GodotNode parent = null)
    {
        auto node = new GodotNode;
        node.name = section.name;
        node.type = section.type;
        node.local = Matrix4x4f.identity();

        auto properties = section.properties.dup;

        // A scene placed as an instance may override properties on its root;
        // the transform already travels with the instance node
        if(options.hasRootOverrides && parent is null)
            foreach(name, value; options.rootOverrides)
                if(name != "transform")
                    properties[name] = value;

        if(auto value = "transform" in properties)
            node.local = as!(GodotTransform3D)(*value).toMatrix;

        if(auto value = "visible" in properties)
            node.visible = asBool(*value, "visible");

        switch(section.type)
        {
            case "DirectionalLight3D":
                node.light.kind = GodotLightKind.directional;
                setLightCommon(node.light, properties);
                node.hasLight = true;
                break;

            case "OmniLight3D":
                node.light.kind = GodotLightKind.point;
                setLightCommon(node.light, properties);
                node.light.range = cast(float) propertyDouble(properties, "omni_range", 5.0);
                node.hasLight = true;
                break;

            case "SpotLight3D":
                node.light.kind = GodotLightKind.spot;
                setLightCommon(node.light, properties);
                node.light.range = cast(float) propertyDouble(properties, "spot_range", 5.0);
                node.light.outerAngle = cast(float) degtorad(propertyDouble(properties, "spot_angle", 45.0));
                node.light.innerAngle = node.light.outerAngle * 0.5f;
                node.hasLight = true;
                break;

            case "Camera3D":
                node.camera.fov = cast(float) propertyDouble(properties, "fov", 75.0);
                node.camera.nearPlane = cast(float) propertyDouble(properties, "near", 0.05);
                node.camera.farPlane = cast(float) propertyDouble(properties, "far", 1000.0);
                node.hasCamera = true;
                break;

            default:
                break;
        }

        if(!isNil(section.instance))
        {
            if(section.instance.type is typeid(GodotObjectRef))
            {
                const instanceRef = asObjectRef(section.instance, "instance");
                if(instanceRef.kind == GodotRefKind.extResource)
                {
                    auto external = findExternal(document, instanceRef.id);
                    if(external !is null && external.type == "PackedScene")
                    {
                        const key = project.resolve(project.key(external.path));

                        if(isGltfPath(key))
                        {
                            const physical = project.physical(key);
                            if(physical.length)
                            {
                                auto gltf = gltfFactory.create(physical);
                                node.instance = gltf;
                                instances ~= node.instance;
                            }
                            else
                                ++skippedResources;
                        }
                        else if(isScenePath(key) && !options.loadStack.canFind(key))
                        {
                            GodotLoadOptions childOptions = options;
                            childOptions.loadStack = options.loadStack ~ scenePath;
                            childOptions.rootOverrides = section.properties;
                            childOptions.hasRootOverrides = true;
                            node.instance = loadGodotScene(project.source, key, pbr, gltfFactory, childOptions);
                            instances ~= node.instance;

                            if(auto child = cast(GodotScene) node.instance)
                                mergeSkipped(child);
                        }
                        else
                            ++skippedResources;
                    }
                    else
                        ++skippedResources;
                }
            }
        }

        if(section.type == "Skeleton3D")
        {
            node.skeleton = parseSkeleton(properties);
            node.hasSkeleton = true;
        }

        if(section.type == "MeshInstance3D")
            createMeshInstance(document, section.name, properties, node, parent);

        if(section.type == "GridMap" && !createGridMap(document, section.name, properties, node))
        {
            ++skippedNodes;
            ++skippedNodeTypes["GridMap"];
        }

        if(isUnsupportedVisualNode(section.type))
        {
            ++skippedNodes;
            ++skippedNodeTypes[section.type];

            bool[string] visited;
            foreach(_, ref value; properties)
                countSkippedResource(document, value, visited);
        }

        return node;
    }

    /// A nested scene keeps its own loader, so bring its report up to the parent
    private void mergeSkipped(GodotScene child)
    {
        skippedNodes += child.skippedNodes;
        skippedResources += child.skippedResources;

        foreach(type, count; child.skippedNodeTypes)
            skippedNodeTypes[type] += count;

        foreach(type, count; child.skippedResourceTypes)
            skippedResourceTypes[type] += count;
    }

    /// Node types that draw or light something in Godot but have no loader support
    private static bool isUnsupportedVisualNode(string type)
    {
        switch(type)
        {
            case "WorldEnvironment":
            case "ReflectionProbe":
            case "LightmapGI":
            case "VoxelGI":
            case "FogVolume":
            case "Decal":
            case "MultiMeshInstance3D":
            case "GPUParticles3D":
            case "CPUParticles3D":
            case "Label3D":
            case "Sprite3D":
            case "AnimatedSprite3D":
                return true;

            default:
                return type.startsWith("CSG");
        }
    }

    /// Resources behind an unsupported node, counted by type so the report names them
    private void countSkippedResource(
        ref GodotTextDocument document,
        in GodotVariant value,
        ref bool[string] visited,
    )
    {
        if(value.type !is typeid(GodotObjectRef))
            return;

        const reference = asObjectRef(value, "resource");

        if(reference.kind == GodotRefKind.subResource)
        {
            const key = "sub:" ~ reference.id;
            if(key in visited)
                return;
            visited[key] = true;

            auto resource = findSubResource(document, reference.id);
            if(resource is null)
                return;

            ++skippedResources;
            ++skippedResourceTypes[resource.type];

            foreach(_, ref property; resource.properties)
                countSkippedResource(document, property, visited);
        }
        else if(reference.kind == GodotRefKind.extResource)
        {
            const key = "ext:" ~ reference.id;
            if(key in visited)
                return;
            visited[key] = true;

            auto external = findExternal(document, reference.id);
            if(external is null)
                return;

            ++skippedResources;
            ++skippedResourceTypes[external.type];
        }
    }

    private static bool isGltfPath(string path)
    {
        return path.endsWith(".glb") || path.endsWith(".gltf");
    }

    private static bool isScenePath(string path)
    {
        return path.endsWith(".tscn") || path.endsWith(".scn") || path.endsWith(".escn");
    }

    private static void setLightCommon(ref GodotLight light, in GodotVariant[string] properties)
    {
        const color = propertyColor(properties, "light_color", GodotColor(1, 1, 1, 1));
        light.color = Vector3f(color.r, color.g, color.b);
        light.energy = cast(float) propertyDouble(properties, "light_energy", 1.0);
    }

    /// Adds one child node per occupied cell, sharing a mesh per library item
    private bool createGridMap(
        ref GodotTextDocument document,
        string nodeName,
        GodotVariant[string] properties,
        GodotNode node,
    )
    {
        auto libraryValue = "mesh_library" in properties;
        if(libraryValue is null || isNil(*libraryValue) || (*libraryValue).type !is typeid(GodotObjectRef))
            return false;

        const reference = asObjectRef(*libraryValue, "mesh_library");

        GodotVariant[string] libraryProperties;
        GodotTextDocument libraryDocument;
        bool libraryInScene;

        if(reference.kind == GodotRefKind.subResource)
        {
            auto resource = findSubResource(document, reference.id);
            if(resource is null || resource.type != "MeshLibrary")
                return false;

            libraryProperties = resource.properties;
            libraryInScene = true;
        }
        else if(reference.kind == GodotRefKind.extResource)
        {
            auto external = findExternal(document, reference.id);
            if(external is null || !isResourcePath(external.path))
                return false;

            libraryDocument = project.document(project.key(external.path));

            if(libraryDocument.resourceType != "MeshLibrary")
                return false;

            libraryProperties = libraryDocument.resourceProperties;
        }
        else
            return false;

        GodotVariant[long] itemMeshes;
        Matrix4x4f[long] itemTransforms;

        foreach(key, ref value; libraryProperties)
        {
            if(!key.startsWith("item/"))
                continue;

            const parts = key.split("/");
            if(parts.length != 3)
                continue;

            const id = parts[1].to!long;

            switch(parts[2])
            {
                case "mesh":
                    if(value.type is typeid(GodotObjectRef))
                        itemMeshes[id] = value;
                    break;

                case "mesh_transform":
                    itemTransforms[id] = as!(GodotTransform3D)(value, key).toMatrix;
                    break;

                default:
                    break;
            }
        }

        auto dataValue = "data" in properties;
        if(dataValue is null)
            return false;

        auto data = asDictionary(*dataValue, "data");
        auto cellsValue = data.get("cells");
        if(cellsValue is null || cellsValue.type !is typeid(int[]))
            return false;

        GridMapCell[] cells;
        try
            cells = decodeGridMapCells(cellsValue.get!(int[])());
        catch(PukanException)
            return false;

        Vector3f cellSize = Vector3f(2, 2, 2);
        if(auto value = "cell_size" in properties)
            cellSize = as!(Vector3f)(*value, "cell_size");

        const halfCell = Vector3f(
            propertyBool(properties, "cell_center_x", true) ? cellSize.x * 0.5f : 0.0f,
            propertyBool(properties, "cell_center_y", true) ? cellSize.y * 0.5f : 0.0f,
            propertyBool(properties, "cell_center_z", true) ? cellSize.z * 0.5f : 0.0f,
        );

        GodotNode[long] templates;

        bool added;
        foreach(cell; cells)
        {
            auto meshValue = cell.item in itemMeshes;
            if(meshValue is null)
                continue;

            auto templateNode = cell.item in templates;
            if(templateNode is null)
            {
                auto created = new GodotNode;
                created.name = nodeName ~ " item " ~ cell.item.to!string;

                GodotVariant[string] meshProperties;
                meshProperties["mesh"] = *meshValue;

                if(libraryInScene)
                    createMeshInstance(document, created.name, meshProperties, created, null);
                else
                    createMeshInstance(libraryDocument, created.name, meshProperties, created, null);

                templates[cell.item] = created;
                templateNode = cell.item in templates;
            }

            if((*templateNode).meshes.length == 0)
                continue;

            auto cellNode = new GodotNode;
            cellNode.name = "Cell";
            cellNode.local = translationMatrix(Vector3f(
                cell.x * cellSize.x,
                cell.y * cellSize.y,
                cell.z * cellSize.z,
            ) + halfCell) * gridMapRotation(cell.rotation);

            if(auto itemTransform = cell.item in itemTransforms)
                cellNode.local *= *itemTransform;

            cellNode.meshes = (*templateNode).meshes;
            node.addChild(cellNode);
            added = true;
        }

        return added;
    }

    private void createMeshInstance(
        ref GodotTextDocument document,
        string nodeName,
        GodotVariant[string] properties,
        GodotNode node,
        GodotNode parent,
    )
    {
        auto meshValue = "mesh" in properties;
        if(meshValue is null || isNil(*meshValue))
            return;

        if((*meshValue).type !is typeid(GodotObjectRef))
        {
            ++skippedResources;
            return;
        }

        const meshRef = asObjectRef(*meshValue, "mesh");
        string documentPath = scenePath;
        GodotTextResource resource;
        bool found;

        if(meshRef.kind == GodotRefKind.subResource)
        {
            auto sub = findSubResource(document, meshRef.id);
            if(sub !is null)
            {
                resource = *sub;
                found = true;
            }
        }
        else if(meshRef.kind == GodotRefKind.extResource)
        {
            auto external = findExternal(document, meshRef.id);
            if(external !is null && isResourcePath(external.path))
            {
                documentPath = project.key(external.path);
                auto externalDocument = project.document(documentPath);
                resource.type = externalDocument.resourceType;
                resource.properties = externalDocument.resourceProperties;
                found = true;
            }
        }

        if(!found)
        {
            ++skippedResources;
            return;
        }

        GodotSkeleton* skeleton;

        if(parent !is null && parent.hasSkeleton)
            skeleton = &parent.skeleton;

        if(auto value = "skeleton" in properties)
        {
            const path = as!(GodotNodePath)(*value, "skeleton").value;

            if(path == ".." && parent !is null && parent.hasSkeleton)
                skeleton = &parent.skeleton;
            else if(path == "." && node.hasSkeleton)
                skeleton = &node.skeleton;
        }

        GodotSkin skin;
        bool hasSkin;

        if(skeleton !is null)
        {
            if(auto value = "skin" in properties)
            {
                skin = resolveSkin(document, asObjectRef(*value, "skin"), *skeleton);

                if(skin !is null)
                {
                    skins ~= skin;
                    hasSkin = true;
                }
            }
        }

        const castShadowMode = cast(int) propertyLong(properties, "cast_shadow", 1);
        const meshKey = documentPath ~ "#" ~ meshRef.id;
        GodotVariant materialOverride;
        if(auto value = "material_override" in properties)
            materialOverride = *value;

        if(resource.type == "ArrayMesh")
        {
            auto surfaces = decodeArrayMesh(resource.properties["_surfaces"]);

            foreach(i, ref surface; surfaces)
            {
                if(surface.primitive != GodotPrimitive.triangles)
                {
                    ++skippedResources;
                    continue;
                }

                GodotVariant surfaceOverride;
                const key = "surface_material_override/" ~ i.to!string;
                if(auto value = key in properties)
                    surfaceOverride = *value;

                addSurfaceMesh(
                    document, documentPath, surface, nodeName, node,
                    materialOverride, surfaceOverride, castShadowMode,
                    meshKey ~ "/" ~ i.to!string ~ (hasSkin ? ":skin" : ""),
                    hasSkin ? skin.info : pbr.resources.identityJointsInfo,
                    hasSkin,
                );
            }
        }
        else if(isPrimitiveMesh(resource.type))
        {
            auto surface = decodePrimitiveSurface(resource.type, resource.properties);

            if(surface.geometry.positions.length == 0)
            {
                ++skippedResources;
                return;
            }

            GodotVariant surfaceOverride;
            if(auto value = "surface_material_override/0" in properties)
                surfaceOverride = *value;

            addSurfaceMesh(
                document, documentPath, surface, nodeName, node,
                materialOverride, surfaceOverride, castShadowMode,
                meshKey ~ "/0" ~ (hasSkin ? ":skin" : ""),
                hasSkin ? skin.info : pbr.resources.identityJointsInfo,
                hasSkin,
            );
        }
        else
            ++skippedResources;
    }

    private static bool isResourcePath(string path)
    {
        import std.algorithm: canFind, endsWith;

        const lower = path.toLower;
        return lower.endsWith(".tres") || lower.endsWith(".tscn") ||
            lower.endsWith(".escn") || lower.endsWith(".res") || lower.endsWith(".scn");
    }

    private GodotArraySurface decodePrimitiveSurface(string type, in GodotVariant[string] properties)
    {
        GodotArraySurface surface;
        surface.primitive = GodotPrimitive.triangles;
        surface.name = type;
        surface.geometry = decodePrimitiveMesh(type, properties);
        surface.aabb = GodotAabb(
            surface.geometry.aabb.min,
            surface.geometry.aabb.max - surface.geometry.aabb.min,
        );

        if(auto material = "material" in properties)
        {
            surface.material = asObjectRef(*material, "material");
            surface.hasMaterial = true;
        }

        return surface;
    }

    private void addSurfaceMesh(
        ref GodotTextDocument document,
        string documentPath,
        ref GodotArraySurface surface,
        string nodeName,
        GodotNode node,
        GodotVariant materialOverride,
        GodotVariant surfaceOverride,
        int castShadowMode,
        string geometryKey,
        VkDescriptorBufferInfo jointInfo,
        bool hasSkin,
    )
    {
        auto material = defaultMaterial(surface.geometry.colors.length > 0, documentPath);

        GodotVariant materialRef;
        if(!isNil(surfaceOverride))
            materialRef = surfaceOverride;
        else if(!isNil(materialOverride))
            materialRef = materialOverride;
        else if(surface.hasMaterial)
            materialRef = GodotVariant(surface.material);

        if(!isNil(materialRef) && materialRef.type is typeid(GodotObjectRef))
            material = resolveMaterial(
                documentPath,
                asObjectRef(materialRef, "material"),
                surface.geometry.colors.length > 0,
            );

        auto mesh = createMesh(surface, material, nodeName, geometryKey, jointInfo, hasSkin);
        mesh.castShadow = castShadowMode != 0;
        mesh.shadowsOnly = castShadowMode == 3;
        node.meshes ~= mesh;
        meshes ~= mesh;
    }

    private GodotMaterialData resolveMaterial(
        string ownerPath,
        GodotObjectRef reference,
        bool hasColors,
    )
    {
        string documentPath = ownerPath;
        string type;
        GodotVariant[string] properties;
        auto owner = project.document(documentPath);

        if(reference.kind == GodotRefKind.subResource)
        {
            auto resource = findSubResource(owner, reference.id);
            if(resource is null)
            {
                ++skippedResources;
                return defaultMaterial(hasColors, documentPath);
            }

            type = resource.type;
            properties = resource.properties;
        }
        else if(reference.kind == GodotRefKind.extResource)
        {
            auto external = findExternal(owner, reference.id);
            if(external is null || !isResourcePath(external.path))
            {
                ++skippedResources;
                return defaultMaterial(hasColors, documentPath);
            }

            documentPath = project.key(external.path);
            auto document = project.document(documentPath);
            type = document.resourceType;
            properties = document.resourceProperties;
        }
        else if(reference.kind == GodotRefKind.resource)
        {
            documentPath = project.key(reference.id);
            auto document = project.document(documentPath);
            type = document.resourceType;
            properties = document.resourceProperties;
        }

        if(type == "StandardMaterial3D" || type == "ORMMaterial3D")
            return readGodotMaterial(type, properties, hasColors, documentPath);

        ++skippedResources;
        return defaultMaterial(hasColors, documentPath);
    }

    private GodotMaterialData defaultMaterial(bool hasColors, string documentPath = "")
    {
        GodotMaterialData result;
        result.material = Material(Vector3f(1, 1, 1), MaterialMode.pbr);
        result.alphaMode = AlphaMode.opaque;
        result.hasVertexColors = hasColors;
        result.documentPath = documentPath;

        if(hasColors)
            result.material.flags = result.material.flags | MaterialFlag.vertexColor;

        return result;
    }

    private PbrMesh createMesh(
        ref GodotArraySurface surface,
        GodotMaterialData material,
        string nodeName,
        string geometryKey,
        VkDescriptorBufferInfo jointInfo,
        bool hasSkin,
    )
    {
        PbrGeometry geometry;

        if(auto cached = geometryKey in geometryCache)
            geometry = *cached;
        else
        {
            MeshStreams streams;

            streams.vertices = upload(surface.geometry.positions, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            streams.normals = upload(surface.geometry.normals, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            streams.tangents = upload(surface.geometry.tangents, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            streams.texCoords = upload(surface.geometry.texCoords, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            streams.colors = upload(surface.geometry.colors, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            streams.joints = upload(surface.geometry.joints, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            streams.weights = upload(surface.geometry.weights, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            streams.aabb = surface.geometry.aabb;

            if(surface.geometry.indices.length)
            {
                const indices = upload(surface.geometry.indices, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
                streams.indices = IndicesDescr(indices, VK_INDEX_TYPE_UINT32);
            }

            geometry = new PbrGeometry(streams, hasSkin, pbr.resources.fallbackVertex.buf);
            geometry.build(gpuBuffs);

            if(geometryKey.length)
                geometryCache[geometryKey] = geometry;
        }

        const name = surface.name.length ? surface.name : nodeName;

        auto mesh = new PbrMesh(
            name,
            geometry,
            allocator,
            pbr.resources.materials,
            fakeTextureInfo,
            jointInfo,
        );

        applyMaterial(mesh, surface, material);

        return mesh;
    }

    private GodotSkin resolveSkin(
        ref GodotTextDocument document,
        GodotObjectRef reference,
        ref GodotSkeleton skeleton,
    )
    {
        string type;
        GodotVariant[string] properties;

        if(reference.kind == GodotRefKind.subResource)
        {
            auto resource = findSubResource(document, reference.id);
            if(resource is null)
                return null;

            type = resource.type;
            properties = resource.properties;
        }
        else if(reference.kind == GodotRefKind.extResource)
        {
            auto external = findExternal(document, reference.id);
            if(external is null || !isResourcePath(external.path))
                return null;

            auto skinDocument = project.document(project.key(external.path));
            type = skinDocument.resourceType;
            properties = skinDocument.resourceProperties;
        }

        if(type != "Skin")
            return null;

        const bindCount = cast(size_t) propertyLong(properties, "bind_count", 0);

        if(bindCount == 0)
            return null;

        Matrix4x4f[] matrices;
        matrices.length = bindCount;
        matrices[] = Matrix4x4f.identity;

        foreach(i; 0 .. bindCount)
        {
            const prefix = "bind/" ~ i.to!string ~ "/";

            int bone = cast(int) propertyLong(properties, prefix ~ "bone", -1);

            if(bone < 0)
            {
                if(auto value = prefix ~ "name" in properties)
                {
                    const name = asString(*value, prefix ~ "name");

                    foreach(index, ref candidate; skeleton.bones)
                        if(candidate.name == name)
                        {
                            bone = cast(int) index;
                            break;
                        }
                }
            }

            if(bone < 0 || cast(size_t) bone >= skeleton.globalPoses.length)
                continue;

            Matrix4x4f bindPose = Matrix4x4f.identity;

            if(auto value = prefix ~ "pose" in properties)
                bindPose = as!(GodotTransform3D)(*value, prefix ~ "pose").toMatrix;

            matrices[i] = skeleton.globalPoses[cast(size_t) bone] * bindPose;
        }

        auto buffer = device.create!TransferBuffer(
            bindCount * Matrix4x4f.sizeof,
            VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );
        (cast(Matrix4x4f[]) buffer.cpuBuf)[] = matrices;

        auto skin = new GodotSkin;
        skin.buffer = buffer;
        skin.matrices = matrices;
        skin.info = VkDescriptorBufferInfo(
            buffer: buffer.gpuBuffer,
            offset: 0,
            range: buffer.length,
        );

        return skin;
    }

    private void applyMaterial(
        PbrMesh mesh,
        ref GodotArraySurface surface,
        in GodotMaterialData material,
    )
    {
        mesh.material = material.material;
        mesh.alphaMode = material.alphaMode;
        mesh.doubleSided = material.doubleSided;

        const hasUv = surface.geometry.texCoords.length > 0;

        if(hasUv)
        {
            auto sampler = samplerFor(material.textureFilter, material.textureRepeat);

            bind(mesh, material.documentPath, material.baseColorTexture, material.hasBaseColorTexture,
                MATERIAL_BASE_COLOR, MaterialFlag.baseColorTexture, true, sampler);

            bind(mesh, material.documentPath, material.normalTexture, material.hasNormalTexture,
                MATERIAL_NORMAL, MaterialFlag.normalTexture, false, sampler);

            bind(mesh, material.documentPath, material.occlusionTexture, material.hasOcclusionTexture,
                MATERIAL_OCCLUSION, MaterialFlag.occlusionTexture, false, sampler);

            bind(mesh, material.documentPath, material.emissiveTexture, material.hasEmissiveTexture,
                MATERIAL_EMISSIVE, MaterialFlag.emissiveTexture, true, sampler);

            bind(mesh, material.documentPath, material.metallicTexture, material.hasMetallicTexture,
                MATERIAL_GODOT_METALLIC, MaterialFlag.godotMetallicTexture, false, sampler);

            bind(mesh, material.documentPath, material.roughnessTexture, material.hasRoughnessTexture,
                MATERIAL_GODOT_ROUGHNESS, MaterialFlag.godotRoughnessTexture, false, sampler);
        }

        if(surface.geometry.tangents.length && material.hasNormalTexture)
            mesh.material.flags = mesh.material.flags | MaterialFlag.vertexTangent;

        if(surface.geometry.normals.length == 0 || mesh.material.mode == MaterialMode.unlit)
            mesh.material.flags = mesh.material.flags | MaterialFlag.derivedNormals;

        mesh.commitMaterial();
    }

    private void bind(
        PbrMesh mesh,
        string documentPath,
        GodotObjectRef objectRef,
        bool present,
        size_t binding,
        MaterialFlag flag,
        bool srgb,
        VkSampler sampler,
    )
    {
        if(!present)
            return;

        auto texture = resolveTexture(documentPath, objectRef, srgb);
        if(texture is null)
            return;

        if(texture.normalTwoChannel && binding == MATERIAL_NORMAL)
            mesh.material.flags = mesh.material.flags | MaterialFlag.godotNormalTwoChannel;

        mesh.bindTexture(binding, flag, VkDescriptorImageInfo(
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            imageView: texture.imageView,
            sampler: sampler,
        ));
    }

    private Texture resolveTexture(string documentPath, GodotObjectRef objectRef, bool srgb)
    {
        if(objectRef.kind != GodotRefKind.extResource)
        {
            ++skippedResources;
            return null;
        }

        if(documentPath.length == 0)
            documentPath = scenePath;

        auto document = project.document(documentPath);
        auto external = findExternal(document, objectRef.id);
        if(external is null)
        {
            ++skippedResources;
            return null;
        }

        const path = project.resolve(project.key(external.path));
        const cacheKey = path ~ (srgb ? ":srgb" : ":linear");

        if(auto cached = cacheKey in textureCache)
            return *cached;

        const lower = path.toLower;
        const isCtex = lower.endsWith(".ctex");

        if(!isCtex && !isImagePath(path))
        {
            ++skippedResources;
            return null;
        }

        const(ubyte)[] imageData;
        GodotCtexImage ctex;

        if(isCtex)
        {
            ctex = loadCtex(project.source.read(path), path);

            if(ctex.levels.length)
            {
                const format = srgb && ctex.srgbFormat != VK_FORMAT_UNDEFINED
                    ? ctex.srgbFormat
                    : ctex.format;

                if(ctex.compressed && !formatSupported(device, format))
                    throw new PukanException(path ~ ": compressed texture format is not supported by the device");

                auto memory = loadImageWithMips(
                    device, commandPool, commandBuffer,
                    ctex.width, ctex.height, ctex.levels, format,
                );
                auto texture = device.create!Texture(
                    memory,
                    ctex.raAsRg ? raAsRgMapping : identityComponentMapping,
                );
                texture.normalTwoChannel = ctex.raAsRg || isTwoChannelNormal(format);
                textureCache[cacheKey] = texture;
                textures ~= texture;
                return texture;
            }

            imageData = ctex.png;
        }
        else
            imageData = project.source.read(path);

        VkFormat format;
        auto image = loadImageFromMemory(imageData, format);

        if(!srgb)
            format = linearFormat(format);

        auto memory = loadImageToMemory(device, commandPool, commandBuffer, image, format);
        auto texture = device.create!Texture(memory);

        textureCache[cacheKey] = texture;
        textures ~= texture;
        return texture;
    }

    private static bool isImagePath(string path)
    {
        import std.algorithm: canFind;

        const ext = extension(path).toLower;
        return [".png", ".jpg", ".jpeg", ".webp", ".tga", ".bmp", ".hdr"].canFind(ext);
    }

    private BufAccess upload(T)(T[] data, VkBufferUsageFlags usage)
    {
        if(data.length == 0)
            return BufAccess();

        auto piece = new BufferPieceOnGPU;
        piece.buffer = new TransferBuffer(device, T.sizeof * data.length, usage);
        (cast(T[]) piece.buffer.cpuBuf)[] = data;
        gpuBuffs ~= piece;

        return BufAccess(
            cast(ptrdiff_t) (gpuBuffs.length - 1),
            0,
            cast(ubyte) T.sizeof,
            cast(uint) data.length,
        );
    }

    private static GodotTextResource* findSubResource(ref GodotTextDocument document, string id)
    {
        foreach(ref resource; document.subResources)
            if(resource.id == id)
                return &resource;

        return null;
    }

    private static GodotTextExternal* findExternal(ref GodotTextDocument document, string id)
    {
        foreach(ref external; document.externals)
            if(external.id == id)
                return &external;

        return null;
    }
}

/// Load one `.tscn`/`.tres` scene from a source project
GodotScene loadGodotScene(
    string filename,
    PbrFactory pbr,
    GltfFactory gltfFactory,
    GodotLoadOptions options = GodotLoadOptions.init,
)
{
    auto loader = new GodotLoader(pbr.device, pbr, gltfFactory, options);
    return loader.run(filename);
}

GodotScene loadGodotScene(
    GodotSource source,
    string scenePath,
    PbrFactory pbr,
    GltfFactory gltfFactory,
    GodotLoadOptions options = GodotLoadOptions.init,
)
{
    auto loader = new GodotLoader(pbr.device, pbr, gltfFactory, options);
    return loader.run(source, scenePath, null);
}
