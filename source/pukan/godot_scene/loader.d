module pukan.godot_scene.loader;

import dlib.math: Matrix4x4f, Vector2f, Vector3f, Vector4f, degtorad;
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
import pukan.godot_scene.scene: GodotCamera, GodotLight, GodotLightKind, GodotNode, GodotScene;
import pukan.godot_scene.text: GodotTextDocument, GodotTextExternal, GodotTextNode, GodotTextResource, parseGodotTextFile;
import pukan.godot_scene.value;
import pukan.gltf: GlTF;
import pukan.gltf.factory: GltfFactory;
import pukan.material: AlphaMode, Material, MaterialFlag, MaterialMode;
import pukan.misc: linearFormat, loadImageFromMemory;
import pukan.pbr.accessor: BufAccess, BufferPieceOnGPU;
import pukan.pbr.factory: PbrFactory;
import pukan.pbr.mesh: IndicesDescr, MeshStreams, PbrGeometry, PbrMesh, Vector4us;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.image: identityComponentMapping, loadImageToMemory, loadImageWithMips;
import pukan.vulkan.pipelines: DescriptorAllocator;
import pukan.vulkan.textures: Texture;
import std.algorithm: canFind, endsWith;
import std.conv: to;
import std.file: exists, getcwd;
import std.path: buildNormalizedPath, buildPath, dirName, extension, isAbsolute, relativePath;
import std.string: replace, startsWith, toLower;

/// Options for loading one Godot scene
struct GodotLoadOptions
{
    /// Overrides the directory found by walking up to `project.godot`
    string projectRoot;
    /// Scene keys already being instantiated, to break cycles
    string[] loadStack;
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

private final class GodotLoader
{
    LogicalDevice device;
    PbrFactory pbr;
    GltfFactory gltfFactory;
    GodotLoadOptions options;
    DescriptorAllocator allocator;

    CommandPool commandPool;
    VkCommandBuffer commandBuffer;
    VkSamplerCreateInfo samplerInfo;

    GodotProject project;
    string scenePath;

    BufferPieceOnGPU[] gpuBuffs;
    PbrMesh[] meshes;
    PbrGeometry[string] geometryCache;
    Texture[] textures;
    Texture[string] textureCache;
    DrawableByVulkan[] instances;
    VkDescriptorImageInfo fakeTextureInfo;

    size_t skippedNodes;
    size_t skippedResources;

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

        samplerInfo = VkSamplerCreateInfo(
            sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            magFilter: VK_FILTER_LINEAR,
            minFilter: VK_FILTER_LINEAR,
            mipmapMode: VK_SAMPLER_MIPMAP_MODE_LINEAR,
            addressModeU: VK_SAMPLER_ADDRESS_MODE_REPEAT,
            addressModeV: VK_SAMPLER_ADDRESS_MODE_REPEAT,
            addressModeW: VK_SAMPLER_ADDRESS_MODE_REPEAT,
            anisotropyEnable: VK_FALSE,
            compareEnable: VK_FALSE,
            compareOp: VK_COMPARE_OP_ALWAYS,
            borderColor: VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            unnormalizedCoordinates: VK_FALSE,
        );
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

        auto scene = new GodotScene(
            pbr.godotPipelines,
            device,
            pbr.resources.materials,
            root,
            meshes,
            gpuBuffs,
            textures,
            instances,
            root.name,
        );
        scene.skippedNodes = skippedNodes;
        scene.skippedResources = skippedResources;
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
            const zAxis = Vector3f(world.a13, world.a23, world.a33).normalized;
            const yAxis = Vector3f(world.a12, world.a22, world.a32).normalized;

            camera.position = Vector3f(world.a14, world.a24, world.a34);
            camera.target = camera.position - zAxis;
            camera.up = yAxis;
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

            auto node = createNode(document, section);
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

    private GodotNode createNode(ref GodotTextDocument document, ref GodotTextNode section)
    {
        auto node = new GodotNode;
        node.name = section.name;
        node.type = section.type;
        node.local = Matrix4x4f.identity();

        if(auto value = "transform" in section.properties)
            node.local = as!(GodotTransform3D)(*value).toMatrix;

        if(auto value = "visible" in section.properties)
            node.visible = asBool(*value, "visible");

        switch(section.type)
        {
            case "DirectionalLight3D":
                node.light.kind = GodotLightKind.directional;
                setLightCommon(node.light, section.properties);
                node.hasLight = true;
                break;

            case "OmniLight3D":
                node.light.kind = GodotLightKind.point;
                setLightCommon(node.light, section.properties);
                node.light.range = cast(float) propertyDouble(section.properties, "omni_range", 5.0);
                node.hasLight = true;
                break;

            case "SpotLight3D":
                node.light.kind = GodotLightKind.spot;
                setLightCommon(node.light, section.properties);
                node.light.range = cast(float) propertyDouble(section.properties, "spot_range", 5.0);
                node.light.outerAngle = cast(float) degtorad(propertyDouble(section.properties, "spot_angle", 45.0));
                node.light.innerAngle = node.light.outerAngle * 0.5f;
                node.hasLight = true;
                break;

            case "Camera3D":
                node.camera.fov = cast(float) propertyDouble(section.properties, "fov", 75.0);
                node.camera.nearPlane = cast(float) propertyDouble(section.properties, "near", 0.05);
                node.camera.farPlane = cast(float) propertyDouble(section.properties, "far", 1000.0);
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
                        else if(isScenePath(external.path) && !options.loadStack.canFind(key))
                        {
                            GodotLoadOptions childOptions = options;
                            childOptions.loadStack = options.loadStack ~ scenePath;
                            node.instance = loadGodotScene(project.source, key, pbr, gltfFactory, childOptions);
                            instances ~= node.instance;
                        }
                        else
                            ++skippedResources;
                    }
                    else
                        ++skippedResources;
                }
            }
        }

        if(section.type == "MeshInstance3D")
            createMeshInstance(document, section, node);

        return node;
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

    private void createMeshInstance(
        ref GodotTextDocument document,
        ref GodotTextNode section,
        GodotNode node,
    )
    {
        auto meshValue = "mesh" in section.properties;
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

        const castShadowMode = cast(int) propertyLong(section.properties, "cast_shadow", 1);
        const meshKey = documentPath ~ "#" ~ meshRef.id;
        GodotVariant materialOverride;
        if(auto value = "material_override" in section.properties)
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
                if(auto value = key in section.properties)
                    surfaceOverride = *value;

                addSurfaceMesh(
                    document, documentPath, surface, section.name, node,
                    materialOverride, surfaceOverride, castShadowMode,
                    meshKey ~ "/" ~ i.to!string,
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
            if(auto value = "surface_material_override/0" in section.properties)
                surfaceOverride = *value;

            addSurfaceMesh(
                document, documentPath, surface, section.name, node,
                materialOverride, surfaceOverride, castShadowMode,
                meshKey ~ "/0",
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

        auto mesh = createMesh(surface, material, nodeName, geometryKey);
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

            geometry = new PbrGeometry(streams, false, pbr.resources.fallbackVertex.buf);
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
            pbr.resources.identityJointsInfo,
        );

        applyMaterial(mesh, surface, material);
        return mesh;
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
            bind(mesh, material.documentPath, material.baseColorTexture, material.hasBaseColorTexture,
                MATERIAL_BASE_COLOR, MaterialFlag.baseColorTexture, true);

            bind(mesh, material.documentPath, material.normalTexture, material.hasNormalTexture,
                MATERIAL_NORMAL, MaterialFlag.normalTexture, false);

            bind(mesh, material.documentPath, material.occlusionTexture, material.hasOcclusionTexture,
                MATERIAL_OCCLUSION, MaterialFlag.occlusionTexture, false);

            bind(mesh, material.documentPath, material.emissiveTexture, material.hasEmissiveTexture,
                MATERIAL_EMISSIVE, MaterialFlag.emissiveTexture, true);

            bind(mesh, material.documentPath, material.metallicTexture, material.hasMetallicTexture,
                MATERIAL_GODOT_METALLIC, MaterialFlag.godotMetallicTexture, false);

            bind(mesh, material.documentPath, material.roughnessTexture, material.hasRoughnessTexture,
                MATERIAL_GODOT_ROUGHNESS, MaterialFlag.godotRoughnessTexture, false);
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
            sampler: texture.sampler,
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
                    memory, samplerInfo,
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
        auto texture = device.create!Texture(memory, samplerInfo);

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
