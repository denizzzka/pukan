module pukan.godot_scene.loader;

import dlib.math: Matrix4x4f, Vector2f, Vector3f, Vector4f;
import material_bindings;
import pukan.exceptions: PukanException;
import pukan.godot_scene.material: GodotMaterialData, readGodotMaterial;
import pukan.godot_scene.mesh: GodotArraySurface, GodotPrimitive, decodeArrayMesh;
import pukan.godot_scene.primitives: decodePrimitiveMesh, isPrimitiveMesh;
import pukan.godot_scene.scene: GodotNode, GodotScene;
import pukan.godot_scene.text: GodotTextDocument, GodotTextExternal, GodotTextNode, GodotTextResource, parseGodotTextFile;
import pukan.godot_scene.value;
import pukan.material: AlphaMode, Material, MaterialFlag, MaterialMode;
import pukan.misc: loadImageFromFile;
import pukan.pbr.accessor: BufAccess, BufferPieceOnGPU;
import pukan.pbr.factory: PbrFactory;
import pukan.pbr.mesh: IndicesDescr, MeshStreams, PbrMesh, Vector4us;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.image: loadImageToMemory;
import pukan.vulkan.pipelines: DescriptorAllocator;
import pukan.vulkan.textures: Texture;
import std.conv: to;
import std.file: exists, getcwd;
import std.path: buildNormalizedPath, buildPath, dirName, extension, isAbsolute;
import std.string: startsWith, toLower;

/// Options for loading one Godot scene
struct GodotLoadOptions
{
    /// Overrides the directory found by walking up to `project.godot`
    string projectRoot;
}

private final class GodotProject
{
    string root;
    GodotTextDocument[string] documents;

    this(string root)
    {
        this.root = root;
    }

    string absolute(string path) const
    {
        if(path.startsWith("res://"))
            return buildPath(root, path[6 .. $]);

        if(isAbsolute(path))
            return buildNormalizedPath(path);

        return buildPath(root, path);
    }

    GodotTextDocument document(string path)
    {
        if(auto cached = path in documents)
            return *cached;

        auto document = parseGodotTextFile(path);
        documents[path] = document;
        return document;
    }
}

private final class GodotLoader
{
    LogicalDevice device;
    PbrFactory pbr;
    GodotLoadOptions options;
    DescriptorAllocator allocator;

    CommandPool commandPool;
    VkCommandBuffer commandBuffer;
    VkSamplerCreateInfo samplerInfo;

    GodotProject project;
    string scenePath;

    BufferPieceOnGPU[] gpuBuffs;
    PbrMesh[] meshes;
    Texture[] textures;
    Texture[string] textureCache;
    VkDescriptorImageInfo fakeTextureInfo;

    size_t skippedNodes;
    size_t skippedResources;

    this(LogicalDevice device, PbrFactory pbr, GodotLoadOptions options)
    {
        this.device = device;
        this.pbr = pbr;
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
        scenePath = absolutePath(filename);

        const rootDir = options.projectRoot.length
            ? buildNormalizedPath(options.projectRoot)
            : findProjectRoot(scenePath);

        project = new GodotProject(rootDir);

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

        auto scene = new GodotScene(
            pbr.godotPipelines,
            pbr.resources.materials,
            root,
            meshes,
            gpuBuffs,
            textures,
            root.name,
        );
        scene.skippedNodes = skippedNodes;
        scene.skippedResources = skippedResources;
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

    private GodotNode createNode(ref GodotTextDocument document, ref GodotTextNode section)
    {
        auto node = new GodotNode;
        node.name = section.name;
        node.local = Matrix4x4f.identity();

        if(auto value = "transform" in section.properties)
            node.local = as!(GodotTransform3D)(*value).toMatrix;

        if(auto value = "visible" in section.properties)
            node.visible = asBool(*value, "visible");

        if(section.type == "MeshInstance3D")
            createMeshInstance(document, section, node);

        return node;
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
        if(meshRef.kind != GodotRefKind.subResource)
        {
            ++skippedResources;
            return;
        }

        auto resource = findSubResource(document, meshRef.id);
        if(resource is null)
        {
            ++skippedResources;
            return;
        }

        if(resource.type == "ArrayMesh")
        {
            auto surfaces = decodeArrayMesh(resource.properties["_surfaces"]);

            foreach(ref surface; surfaces)
            {
                if(surface.primitive != GodotPrimitive.triangles)
                {
                    ++skippedResources;
                    continue;
                }

                addSurfaceMesh(document, surface, section.name, node);
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

            addSurfaceMesh(document, surface, section.name, node);
        }
        else
            ++skippedResources;
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
        ref GodotArraySurface surface,
        string nodeName,
        GodotNode node,
    )
    {
        auto material = defaultMaterial(surface.geometry.colors.length > 0);

        if(surface.hasMaterial)
        {
            auto materialResource = findSubResource(document, surface.material.id);

            if(materialResource !is null)
            {
                if(materialResource.type == "StandardMaterial3D" || materialResource.type == "ORMMaterial3D")
                    material = readGodotMaterial(
                        materialResource.type,
                        materialResource.properties,
                        surface.geometry.colors.length > 0,
                    );
                else
                    ++skippedResources;
            }
        }

        auto mesh = createMesh(document, surface, material, nodeName);
        node.meshes ~= mesh;
        meshes ~= mesh;
    }

    private GodotMaterialData defaultMaterial(bool hasColors)
    {
        GodotMaterialData result;
        result.material = Material(Vector3f(1, 1, 1), MaterialMode.pbr);
        result.alphaMode = AlphaMode.opaque;
        result.hasVertexColors = hasColors;

        if(hasColors)
            result.material.flags = result.material.flags | MaterialFlag.vertexColor;

        return result;
    }

    private PbrMesh createMesh(
        ref GodotTextDocument document,
        ref GodotArraySurface surface,
        GodotMaterialData material,
        string nodeName,
    )
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

        const name = surface.name.length ? surface.name : nodeName;

        auto mesh = new PbrMesh(
            name,
            streams,
            allocator,
            pbr.resources.materials,
            fakeTextureInfo,
            false,
            pbr.resources.fallbackVertex.buf,
            pbr.resources.identityJointsInfo,
        );

        applyMaterial(mesh, document, surface, material);
        mesh.buildGeometry(gpuBuffs);
        return mesh;
    }

    private void applyMaterial(
        PbrMesh mesh,
        ref GodotTextDocument document,
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
            bind(mesh, document, material.baseColorTexture, material.hasBaseColorTexture,
                MATERIAL_BASE_COLOR, MaterialFlag.baseColorTexture);

            bind(mesh, document, material.normalTexture, material.hasNormalTexture,
                MATERIAL_NORMAL, MaterialFlag.normalTexture);

            bind(mesh, document, material.occlusionTexture, material.hasOcclusionTexture,
                MATERIAL_OCCLUSION, MaterialFlag.occlusionTexture);

            bind(mesh, document, material.emissiveTexture, material.hasEmissiveTexture,
                MATERIAL_EMISSIVE, MaterialFlag.emissiveTexture);

            bind(mesh, document, material.metallicTexture, material.hasMetallicTexture,
                MATERIAL_GODOT_METALLIC, MaterialFlag.godotMetallicTexture);

            bind(mesh, document, material.roughnessTexture, material.hasRoughnessTexture,
                MATERIAL_GODOT_ROUGHNESS, MaterialFlag.godotRoughnessTexture);
        }

        if(surface.geometry.tangents.length && material.hasNormalTexture)
            mesh.material.flags = mesh.material.flags | MaterialFlag.vertexTangent;

        if(surface.geometry.normals.length == 0 || mesh.material.mode == MaterialMode.unlit)
            mesh.material.flags = mesh.material.flags | MaterialFlag.derivedNormals;

        mesh.commitMaterial();
    }

    private void bind(
        PbrMesh mesh,
        ref GodotTextDocument document,
        GodotObjectRef objectRef,
        bool present,
        size_t binding,
        MaterialFlag flag,
    )
    {
        if(!present)
            return;

        auto texture = resolveTexture(document, objectRef);
        if(texture is null)
            return;

        mesh.bindTexture(binding, flag, VkDescriptorImageInfo(
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            imageView: texture.imageView,
            sampler: texture.sampler,
        ));
    }

    private Texture resolveTexture(ref GodotTextDocument document, GodotObjectRef objectRef)
    {
        if(objectRef.kind != GodotRefKind.extResource)
        {
            ++skippedResources;
            return null;
        }

        auto external = findExternal(document, objectRef.id);
        if(external is null)
        {
            ++skippedResources;
            return null;
        }

        const path = project.absolute(external.path);

        if(auto cached = path in textureCache)
            return *cached;

        if(!isImagePath(path))
        {
            ++skippedResources;
            return null;
        }

        VkFormat format;
        auto image = loadImageFromFile(path, format);
        auto memory = loadImageToMemory(device, commandPool, commandBuffer, image, format);
        auto texture = device.create!Texture(memory, samplerInfo);

        textureCache[path] = texture;
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
    GodotLoadOptions options = GodotLoadOptions.init,
)
{
    auto loader = new GodotLoader(pbr.device, pbr, options);
    return loader.run(filename);
}
