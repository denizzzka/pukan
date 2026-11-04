module pukan.graphics.g3d.scene;

import dlib.math: translation, Matrix4x4f, Vector3f, Vector4f;
import pukan;
import pukan.graphics.common.frame_bindings: frameBindings, frameSetBindings;
import pukan.graphics.g3d.cells: CellGrid;
import pukan.graphics.common.screenshot: Screenshot;
import pukan.graphics.g3d.axes: Axis;
import pukan.graphics.g3d.ibl: createIblTextures, IblTextures;
import pukan.graphics.g3d.mesh: MeshResources;
import pukan.graphics.g3d.occlusion_depth: OcclusionDepth;
import pukan.graphics.g3d.oit: DepthResolve, OitFrame, OitResolve;
import pukan.graphics.g3d.pbr.culling: CullFrame, currentCullFrame;
import pukan.graphics.g3d.pbr.instancing: InstanceArena, currentInstanceArena;
import pukan.graphics.g3d.pbr.lod: currentViewportHeight;
import pukan.graphics.g3d.pbr.pipeline_set: PbrPipelineSet, createPbrPipelineSet;
import pukan.graphics.g3d.pbr.pipelines: oitPass, transmissionPass, pipelineWarmupEnabled, pipelineWarmupEverything, pipelineWarmupPerScene, pipelineWarmupRequired, Variants;
import pukan.graphics.g3d.pbr.pipelines: PbrProfile, pbrGltfActive, pbrGodotActive;
import pukan.graphics.g3d.primitives_tree.cylinder: CylinderRenderer;
import pukan.graphics.g3d.primitives_tree.sphere: SphereRenderer;
import pukan.graphics.g3d.shadow: SunShadow;
import pukan.vulkan.bindings;
import pukan.vulkan.pipeline_cache: FilePipelineCacheStore, PipelineCacheStore;
import pukan.vulkan.resources.ownership: ResourceOwner;
import pukan.vulkan.resources.vkobj: VkObj;
import std.uuid: UUID;

class SceneWith(Modules...)
{
    alias PipelineVariants = Variants!Modules;

    /// The axis the ground lies across: characters turn around it and take their heading from it
    Axis up = Axis.y;

    LogicalDevice device;
    VkSurfaceKHR surface;
    VkSurfaceFormatKHR surfaceFormat;

    alias WindowSizeChangeDetectedCallback = void delegate();
    WindowSizeChangeDetectedCallback windowSizeChanged;

    SwapChain swapChain;
    FrameBuilder frameBuilder;
    DefaultRenderPass renderPass; //TODO: replace by RenderPass base?
    Background background;
    /// Coarse depth of the last frame, when the occlusion grid is on
    private OcclusionDepth occlusionDepth;
    VkPresentModeKHR presentMode;

    VkQueue graphicsQueue;
    VkQueue presentQueue;

    import pukan.graphics.g3d.primitives_tree: PrimitivesFactory;
    PipelineFactory pipelineFactory;
    /// Persists driver pipeline caches between runs, null when none is configured
    PipelineCacheStore pipelineCacheStore;
    /// Shared by the factory and the compute kernels, null with no store
    PipelineCacheManager pipelineCacheManager;
    private DescriptorAllocator frameAllocator;
    MeshResources meshResources;
    PrimitivesFactory!ColoredMesh coloredMeshFactory;
    PrimitivesFactory!(pukan.graphics.g3d.primitives_tree.mesh.TexturedMesh) texturedMeshFactory;
    PrimitivesFactory!(pukan.graphics.g3d.primitives_tree.mesh.LitMesh) litMeshFactory;
    GltfFactory gltfFactory;
    GodotFactory godotFactory;
    PbrFactory pbrFactory;
    PbrPipelineSet pbrPipelineSet;
    SphereRenderer sphereRenderer;
    CylinderRenderer cylinderRenderer;
    IblTextures ibl;

    /// Blended draws store their fragments in per-pixel lists this resolves
    bool oitEnabled = true;

    private Screenshot pendingScreenshot;
    private string pendingScreenshotPath;
    /// Path of the frame saved by the last `captureFrame` call
    string lastScreenshotPath;

    /// The sun's shadow map and its cache
    SunShadow sunShadow;
    private VkObj!VkSampler resolveSampler;
    private OitResolve oitResolve;
    private DepthResolve depthResolve;
    /// OIT images of the current swapchain, indexed like its frames
    private OitFrame[] oitFrames;
    /// OIT images of the current swapchain; released before its frame sets go
    private ResourceOwner!false oitOwner;
    /// Set after the first frame has waited for the preload queue
    private bool pipelinesReady;

    float exposure = 1.0f;
    float iblIntensity = 1.0f;
    /// Ambient tint and energy applied to the IBL term
    Vector4f ambientLight = Vector4f(1, 1, 1, 1);
    /// Godot tonemap mode: linear, Reinhard, Filmic, ACES, AgX
    uint tonemapMode = 3;
    float tonemapWhite = 1.0f;
    /// Partition of the world that cells and streaming work from
    CellGrid cellGrid;

    /// Uploaded with the frame; the first entry is the sun
    private Light[maxLights] lights;
    private uint lightCount;
    private MemoryBufferMappedToCPU[] lightBufs;
    private InstanceArena[] instanceArenas;
    private CullFrame[] cullFrames;

    /// Scene-lifetime resources; it destroys what it took newest first
    private ResourceOwner!false sceneOwner;
    /// What a swapchain rebuild replaces: lists, cull frames, OIT images
    private ResourceOwner!false screenOwner;

    void addPointLight(Vector3f position, Vector3f color, float radius)
    {
        addLight(Light(
            Vector4f(position.x, position.y, position.z, radius),
            Vector4f(0, 0, 0, 0),
            Vector4f(color.x, color.y, color.z, 0),
            Vector4f(cast(float) LightType.point, 0, 0, 0),
        ));
    }

    void addSpotLight(
        Vector3f position,
        Vector3f direction,
        Vector3f color,
        float radius,
        float innerAngle,
        float outerAngle,
    )
    {
        import std.math: cos;

        const beam = direction.normalized;

        addLight(Light(
            Vector4f(position.x, position.y, position.z, radius),
            Vector4f(beam.x, beam.y, beam.z, cos(outerAngle)),
            Vector4f(color.x, color.y, color.z, 0),
            Vector4f(cast(float) LightType.spot, cos(innerAngle), 0, 0),
        ));
    }

    /// Replaces the sun; the direction points from the scene toward the light
    void setSun(Vector3f direction, Vector3f color, float intensity = 1.0f)
    {
        const dir = direction.normalized;

        lights[0] = Light(
            Vector4f(dir.x, dir.y, dir.z, 0),
            Vector4f(0, 0, 0, 0),
            Vector4f(color.x * intensity, color.y * intensity, color.z * intensity, 0),
            Vector4f(cast(float) LightType.directional, 0, 0, 0),
        );

        sunShadow.invalidate();
    }

    /// Number of lights already added, including the sun
    uint activeLightCount() const => lightCount;

    private void addLight(Light light)
    {
        import std.exception: enforce;

        enforce(lightCount < maxLights, "too many lights");

        lights[lightCount++] = light;
    }

    /// Whether transmissive meshes get a second pass after a copy of the frame.
    /// They sample that copy to show what lies behind them; with the pass off
    /// they are drawn with the rest and fall back to the environment.
    bool transmissionPassEnabled = true;

    this(
        LogicalDevice dev,
        VkSurfaceKHR surf,
        WindowSizeChangeDetectedCallback wsc,
        VkSurfaceFormatKHR surfaceFormat,
        string appName,
        VkPresentModeKHR presentMode = VK_PRESENT_MODE_FIFO_KHR,
        PipelineCacheStore pipelineCacheStore = null,
    )
    {
        this(dev, surf, wsc, surfaceFormat, appName, presentMode, pipelineCacheStore, false, VkExtent2D.init);
    }

    /// Renders into owned images without a surface or a window
    this(
        LogicalDevice dev,
        VkExtent2D extent,
        VkFormat format,
        string appName,
        PipelineCacheStore pipelineCacheStore = null,
    )
    {
        this(
            dev,
            null,
            null,
            VkSurfaceFormatKHR(format, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR),
            appName,
            VK_PRESENT_MODE_FIFO_KHR,
            pipelineCacheStore,
            true,
            extent,
        );
    }

    private this(
        LogicalDevice dev,
        VkSurfaceKHR surf,
        WindowSizeChangeDetectedCallback wsc,
        VkSurfaceFormatKHR surfaceFormat,
        string appName,
        VkPresentModeKHR presentMode,
        PipelineCacheStore pipelineCacheStore,
        bool offscreen,
        VkExtent2D offscreenExtent,
    )
    {
        device = dev;
        surface = surf;
        windowSizeChanged = wsc;
        this.surfaceFormat = surfaceFormat;
        this.presentMode = presentMode;

        sceneOwner = new ResourceOwner!false("scene", device.rootOwner.releaseQueue);

        const sun = Vector3f(0.35f, 0.5f, -0.8f).normalized;
        lights[0] = Light(
            Vector4f(sun.x, sun.y, sun.z, 0),
            Vector4f(0, 0, 0, 0),
            Vector4f(1, 1, 1, 1),
            Vector4f(cast(float) LightType.directional, 0, 0, 0),
        );
        lightCount = 1;

        if(surface)
            device.physicalDevice.instance.useSurface(surface);

        renderPass = device.create!DefaultRenderPass(surfaceFormat.format);

        if(pipelineCacheStore)
            this.pipelineCacheStore = pipelineCacheStore;
        else
        {
            const cacheDirectory = FilePipelineCacheStore.defaultDirectory(appName);

            if(cacheDirectory.length > 0)
                this.pipelineCacheStore = new FilePipelineCacheStore(
                    cacheDirectory,
                    UUID(device.physicalDevice.properties.pipelineCacheUUID),
                );
        }

        if(this.pipelineCacheStore)
        {
            pipelineCacheManager = new PipelineCacheManager(device, this.pipelineCacheStore);
            device.pipelineCacheManager = pipelineCacheManager;
        }

        pipelineFactory = new PipelineFactory(device, frameSetBindings, pipelineCacheManager, pipelineWarmupEnabled);
        pipelineFactory.eagerCompute = pipelineWarmupEverything || pipelineWarmupRequired;
        frameAllocator = pipelineFactory.createFrameAllocator();
        meshResources = new MeshResources(device);
        ibl = createIblTextures(device);

        background = new Background(device, pipelineFactory, renderPass);

        oitResolve = new OitResolve(device, pipelineFactory, surfaceFormat.format);
        depthResolve = new DepthResolve(device, pipelineFactory);

        sunShadow = new SunShadow(device);

        {
            VkSamplerCreateInfo samplerInfo = {
                sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                magFilter: VK_FILTER_NEAREST,
                minFilter: VK_FILTER_NEAREST,
                mipmapMode: VK_SAMPLER_MIPMAP_MODE_NEAREST,
                addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                compareEnable: VK_FALSE,
                unnormalizedCoordinates: VK_FALSE,
            };
            resolveSampler = VkObj!VkSampler(device.releaseQueue, samplerInfo);
        }

        frameBuilder = device.create!FrameBuilder(WorldTransformation.sizeof);
        swapChain = offscreen
            ? new SwapChain(device, frameBuilder, offscreenExtent, surfaceFormat.format, renderPass)
            : new SwapChain(device, frameBuilder, surface, renderPass, null, surfaceFormat.colorSpace, presentMode);
        createFrameSets();

        coloredMeshFactory = PrimitivesFactory!ColoredMesh(device, pipelineFactory, meshResources, renderPass);
        texturedMeshFactory = PrimitivesFactory!TexturedMesh(device, pipelineFactory, meshResources, renderPass);
        litMeshFactory = PrimitivesFactory!LitMesh(device, pipelineFactory, meshResources, renderPass);
        pbrPipelineSet = createPbrPipelineSet(pipelineFactory, renderPass, sunShadow.pass);
        pbrFactory = new PbrFactory(device, pipelineFactory, meshResources, pbrPipelineSet.materialLayout);
        static if(pipelineWarmupRequired)
        {
            static if(Modules.length == 0)
            {
                pbrPipelineSet.warmAll();
                pipelineFactory.waitForRequests();
                pbrPipelineSet.validateAll();
            }
            else
            {
                pbrPipelineSet.warmVariants!PipelineVariants();
                pipelineFactory.waitForRequests();
            }
        }
        else static if(pipelineWarmupEverything)
        {
            pbrPipelineSet.warmAll();
            pipelineFactory.waitForRequests();
            pbrPipelineSet.validateAll();
        }
        static if(pbrGltfActive)
            gltfFactory = new GltfFactory(pbrFactory, pbrPipelineSet.pipelinesFor(GltfFactory.pbrProfile));
        static if(pbrGodotActive)
            godotFactory = new GodotFactory(
                pbrFactory,
                gltfFactory,
                pbrPipelineSet.pipelinesFor(GodotFactory.pbrProfile),
            );
        sphereRenderer = new SphereRenderer(device, pipelineFactory, renderPass, meshResources.fakeTexture);
        cylinderRenderer = new CylinderRenderer(device, pipelineFactory, renderPass, meshResources.fakeTexture);

        // Registered in the reverse of the destruction order: newest goes first
        sceneOwner.own(renderPass);

        if(pipelineCacheManager)
            sceneOwner.own(pipelineCacheManager);

        sceneOwner.own(meshResources);
        sceneOwner.own(ibl.brdfLut);
        sceneOwner.own(ibl.prefiltered);
        sceneOwner.own(ibl.irradiance);

        if(pbrFactory)
            sceneOwner.own(pbrFactory);

        if(gltfFactory)
            sceneOwner.own(gltfFactory);

        if(godotFactory)
            sceneOwner.own(godotFactory);

        sceneOwner.own(frameBuilder);
        sceneOwner.own(swapChain);
        sceneOwner.own(oitResolve);
        sceneOwner.own(depthResolve);
        sceneOwner.own(sunShadow);
        sceneOwner.own(background);
        sceneOwner.own(pipelineFactory);
        sceneOwner.own(frameAllocator);
    }

    ~this()
    {
        // A worker may still read a pass or shader module below
        static if(pipelineWarmupEnabled)
            if(pipelineFactory)
                pipelineFactory.waitForRequests();

        if(pendingScreenshot)
            destroy(pendingScreenshot);

        // Asset sets live in the factory pools, so they go before them
        if(gltfFactory)
            gltfFactory.destroyAssets();

        if(screenOwner)
            destroy(screenOwner);

        if(sceneOwner)
        {
            if(pipelineCacheManager)
                device.pipelineCacheManager = null;

            destroy(sceneOwner);
        }
    }

    private void createFrameSets()
    {
        VkDescriptorImageInfo imageInfo(Texture texture)
        {
            return VkDescriptorImageInfo(
                imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                imageView: texture.imageView,
                sampler: texture.sampler,
            );
        }

        auto irradiance = imageInfo(ibl.irradiance);
        auto prefiltered = imageInfo(ibl.prefiltered);
        auto brdfLut = imageInfo(ibl.brdfLut);

        // The device queue keeps the OIT images of a replaced chain for its
        // frames in flight, so everything here can go at once
        oitOwner = null;

        if(screenOwner)
            destroy(screenOwner);
        screenOwner = new ResourceOwner!false("screen", sceneOwner.releaseQueue);

        oitOwner = new ResourceOwner!false("oit", screenOwner.releaseQueue);
        screenOwner.own(oitOwner);

        lightBufs.length = swapChain.frames.length;

        instanceArenas.length = swapChain.frames.length;
        foreach(i; 0 .. instanceArenas.length)
        {
            instanceArenas[i] = new InstanceArena(device);
            screenOwner.own(instanceArenas[i]);
        }

        cullFrames.length = swapChain.frames.length;
        foreach(i; 0 .. cullFrames.length)
        {
            cullFrames[i] = new CullFrame(device, pipelineFactory);
            screenOwner.own(cullFrames[i]);
        }

        sunShadow.recreate(swapChain.frames.length);

        foreach(ref frame; swapChain.frames)
            frame.sceneColor = createSceneColorTexture(swapChain.imageExtent);

        oitFrames = null;
        oitFrames.length = swapChain.frames.length;

        foreach(i, ref frame; swapChain.frames)
        {
            auto sceneColor = imageInfo(frame.sceneColor);

            lightBufs[i] = device.create!MemoryBufferMappedToCPU(maxLights * Light.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
            screenOwner.own(lightBufs[i]);

            auto shadowInfo = sunShadow.imageInfo(i);
            auto lightInfo = VkDescriptorBufferInfo(
                buffer: lightBufs[i].buf,
                offset: 0,
                range: maxLights * Light.sizeof,
            );

            oitFrames[i] = new OitFrame(device, oitResolve.pass, depthResolve.pass, frame.imageView, swapChain.imageExtent);
            oitOwner.own(oitFrames[i]);

            auto oitHeads = oitFrames[i].headsImageInfo;
            auto oitFragments = oitFrames[i].fragmentsInfo;
            auto oitCounter = oitFrames[i].counterInfo;
            auto sceneDepth = oitFrames[i].sceneDepthInfo();
            sceneDepth.sampler = resolveSampler.vk;

            auto depthMS = VkDescriptorImageInfo(
                imageLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
                imageView: frame.depthBuf.depthView,
                sampler: resolveSampler.vk,
            );

            foreach(eye; 0 .. 2)
                frame.frameSets[eye] = new FrameSet(
                    device,
                    frameAllocator,
                    FrameUniforms.sizeof,
                    frameBindings,
                    irradiance,
                    prefiltered,
                    brdfLut,
                    sceneColor,
                    oitHeads,
                    oitFragments,
                    oitCounter,
                    lightInfo,
                    shadowInfo,
                    sceneDepth,
                    depthMS,
                );
        }
    }

    /// Copy of the colour the first pass leaves, sampled by transmissive draws
    private Texture createSceneColorTexture(VkExtent2D extent)
    {
        import std.algorithm: max;

        uint mipLevels = 1;
        for(uint size = max(extent.width, extent.height); size > 1 && mipLevels < 4; size >>= 1)
            ++mipLevels;

        VkImageCreateInfo cinf = {
            imageType: VK_IMAGE_TYPE_2D,
            format: surfaceFormat.format,
            tiling: VK_IMAGE_TILING_OPTIMAL,
            extent: VkExtent3D(extent.width, extent.height, 1),
            mipLevels: mipLevels,
            arrayLayers: 1,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usage: VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
            sharingMode: VK_SHARING_MODE_EXCLUSIVE,
            samples: VK_SAMPLE_COUNT_1_BIT,
        };

        auto image = device.create!ImageMemory(cinf, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        auto pool = device.createCommandPool();
        auto bufs = pool.allocateBuffers(1);

        pool.recordOneTimeAndSubmit(bufs[0], (VkCommandBuffer buf) {
            imageBarrier(
                buf, image.image,
                VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, 0,
                VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
                0, mipLevels,
            );

            imageBarrier(
                buf, image.image,
                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_ACCESS_SHADER_READ_BIT,
                0, mipLevels,
            );
        });

        pool.freeBuffers(bufs);
        destroy(pool);

        VkSamplerCreateInfo samplerInfo = {
            sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            magFilter: VK_FILTER_LINEAR,
            minFilter: VK_FILTER_LINEAR,
            mipmapMode: VK_SAMPLER_MIPMAP_MODE_LINEAR,
            addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            borderColor: VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            unnormalizedCoordinates: VK_FALSE,
            compareEnable: VK_FALSE,
            compareOp: VK_COMPARE_OP_ALWAYS,
            minLod: 0,
            maxLod: VK_LOD_CLAMP_NONE,
        };

        return device.create!Texture(image, samplerInfo);
    }

    /// Transitions one image subresource between layouts
    static void imageBarrier(
        VkCommandBuffer buf,
        VkImage image,
        VkImageLayout oldLayout,
        VkImageLayout newLayout,
        VkPipelineStageFlags srcStage,
        VkAccessFlags srcAccess,
        VkPipelineStageFlags dstStage,
        VkAccessFlags dstAccess,
        uint baseMip = 0,
        uint mipCount = 1,
        VkImageAspectFlags aspect = VK_IMAGE_ASPECT_COLOR_BIT,
    )
    {
        transitionImageLayout(buf, image, oldLayout, newLayout, srcStage, srcAccess,
            dstStage, dstAccess, baseMip, mipCount, aspect);
    }

    /// Hands the colour to the presentation engine when nothing samples it
    private void presentColor(ref Frame frame)
    {
        // An offscreen image has no presentation layout
        if(swapChain.isOffscreen())
            return;

        imageBarrier(
            frame.commandBuffer, frame.image,
            VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0,
        );
    }

    /// Copies the colour the first pass left into the frame's scene texture
    private void copySceneColor(ref Frame frame)
    {
        import std.algorithm: max;

        auto cb = frame.commandBuffer;
        auto color = frame.sceneColor.textureImageMemory;
        const extent = swapChain.imageExtent;

        imageBarrier(
            cb, frame.image,
            VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT,
        );

        imageBarrier(
            cb, color.image,
            VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_ACCESS_SHADER_READ_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
        );

        VkImageCopy region;
        region.srcSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.srcSubresource.mipLevel = 0;
        region.srcSubresource.layerCount = 1;
        region.dstSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        region.dstSubresource.mipLevel = 0;
        region.dstSubresource.layerCount = 1;
        region.extent = VkExtent3D(extent.width, extent.height, 1);

        vkCmdCopyImage(
            cb,
            frame.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            color.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1, &region,
        );

        imageBarrier(
            cb, color.image,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT,
        );

        int width = cast(int) extent.width;
        int height = cast(int) extent.height;

        foreach(level; 1 .. color.mipLevels)
        {
            imageBarrier(
                cb, color.image,
                VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_ACCESS_SHADER_READ_BIT,
                VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
                level, 1,
            );

            const int nextWidth = max(width / 2, 1);
            const int nextHeight = max(height / 2, 1);

            VkImageBlit blit;
            blit.srcSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            blit.srcSubresource.mipLevel = level - 1;
            blit.srcSubresource.layerCount = 1;
            blit.dstSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            blit.dstSubresource.mipLevel = level;
            blit.dstSubresource.layerCount = 1;
            blit.srcOffsets[1] = VkOffset3D(width, height, 1);
            blit.dstOffsets[1] = VkOffset3D(nextWidth, nextHeight, 1);

            vkCmdBlitImage(
                cb,
                color.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                color.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                1, &blit, VK_FILTER_LINEAR,
            );

            imageBarrier(
                cb, color.image,
                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
                VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT,
                level, 1,
            );

            width = nextWidth;
            height = nextHeight;
        }

        imageBarrier(
            cb, color.image,
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_ACCESS_SHADER_READ_BIT,
            0, color.mipLevels,
        );

        imageBarrier(
            cb, frame.image,
            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_READ_BIT,
            VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        );
    }

    void updateFrameUniforms(ref Frame frame, size_t eye, in WorldTransformation wtb)
    {
        const viewProj = wtb.proj * wtb.view;
        const camera = translation(wtb.view.inverse);

        FrameUniforms data;
        data.invViewProj = viewProj.inverse;
        data.viewProj = viewProj;
        data.cameraPosition = Vector4f(camera.x, camera.y, camera.z, 1);

        // The light matrix is only needed while the shadow pass runs
        if(sunShadow.enabled)
        {
            const sun = Vector3f(
                lights[0].positionRadius.x,
                lights[0].positionRadius.y,
                lights[0].positionRadius.z,
            );
            sunShadow.update(sun);
            data.shadowViewProj = sunShadow.viewProj;
        }

        data.shadowParams = Vector4f(sunShadow.enabled ? 1 : 0, sunShadow.depthBias, 0, 0);
        data.ambientParams = ambientLight;
        data.tonemapParams = Vector4f(cast(float) tonemapMode, tonemapWhite, 0, 0);
        data.exposureParams = Vector4f(
            exposure,
            iblIntensity,
            transmissionPassEnabled ? 1 : 0,
            cast(float) lightCount,
        );

        auto lightBuffer = lightBufs[frameIndex(frame)];
        const lightBytes = lightCount * Light.sizeof;
        (cast(Light[]) lightBuffer.cpuBuf[0 .. lightBytes])[] = lights[0 .. lightCount];

        frame.frameSets[eye].update(data);
    }

    void recordCommandBuffer(
        ref Frame frame,
        SceneDrawCallback drawScene,
        SceneDrawCallback drawTransmission = null,
        void delegate(ref VkCommandBuffer) drawShadow = null,
        void delegate(ref VkCommandBuffer) prepare = null,
    )
    {
        auto commandBuffer = frame.commandBuffer;

        currentInstanceArena = instanceArenas[frameIndex(frame)];
        currentInstanceArena.reset();
        currentViewportHeight = cast(float) swapChain.imageExtent.height;

        if(cullFrames.length)
        {
            currentCullFrame = cullFrames[frameIndex(frame)];
            currentCullFrame.reset();

            // The last frame's grid is what this frame's kernel tests against
            currentCullFrame.setOcclusion(
                occlusionDepth !is null ? occlusionDepth.view : null,
                occlusionDepth !is null ? occlusionDepth.readSampler : VkSampler.init,
                occlusionDepth !is null ? cast(uint) occlusionDepth.columns : 0,
                occlusionDepth !is null ? cast(uint) occlusionDepth.rows : 0,
            );
        }

        // Compute work, such as a cull kernel, has to finish before a pass begins
        if(prepare !is null)
            prepare(commandBuffer);

        transmissionPass = transmissionPassEnabled;
        oitPass = oitEnabled;

        recordShadow(frame, drawShadow);

        clearOit(frame);

        renderPass.recordCommandBuffer(
            commandBuffer,
            (ref VkCommandBuffer buf) { background.draw(buf, swapChain.imageExtent); },
            (ref VkCommandBuffer buf) {
                drawScene(buf, DrawPhase.surface);
                drawScene(buf, DrawPhase.blended);
            },
        );

        if(occlusionDepth !is null)
            occlusionDepth.record(
                commandBuffer,
                frame.depthBuf.depthImage.image,
                frame.depthBuf.depthView,
                swapChain.imageExtent,
                cast(uint) renderPass.samples,
            );

        if(oitEnabled)
            resolveOit(frame, false);

        if(transmissionPassEnabled)
        {
            copySceneColor(frame);

            renderPass.recordTransmissionCommandBuffer(
                commandBuffer,
                (ref VkCommandBuffer buf) {
                    if(drawTransmission !is null)
                        drawTransmission(buf, DrawPhase.transmission);
                },
            );

            if(oitEnabled)
            {
                // Glass hides blended fragments behind it, the visible ones stay
                resolveDepth(frame);
                resolveOit(frame, true);
            }
        }

        recordPendingScreenshot(frame);
        presentColor(frame);

        // Frees what no frame in flight can still reference
        //TODO: the scene drives this; hang it on frame completion instead
        device.flushRetired(cast(uint) swapChain.frames.length);
    }

    /// Starts feeding the coarse depth grid from this scene's frames
    void enableOcclusionDepth(int columns, int rows)
    {
        if(occlusionDepth is null)
            occlusionDepth = new OcclusionDepth(device, pipelineFactory, columns, rows);
    }

    /// Instances the last frame's grid dropped from the camera's view
    size_t occlusionRejections()
    {
        return currentCullFrame !is null ? currentCullFrame.occlusionRejections : 0;
    }

    /// Copies the last grid into `cells`; false while no frame has written one
    bool readOcclusionDepths(float[] cells)
    {
        return occlusionDepth !is null && occlusionDepth.read(cells);
    }

    alias SceneDrawCallback = void delegate(ref VkCommandBuffer, DrawPhase phase);
    alias StereoDrawCallback = void delegate(ref VkCommandBuffer, size_t eye, VkExtent2D eyeExtent, DrawPhase phase);

    private void drawStereoEyes(VkCommandBuffer buf, StereoDrawCallback drawScene, bool transmission = false)
    {
        const extent = swapChain.imageExtent;
        const leftWidth = extent.width / 2;
        const rightWidth = extent.width - leftWidth;

        foreach(size_t eye; 0 .. 2)
        {
            const width = eye == 0 ? leftWidth : rightWidth;
            const x = eye == 0 ? 0 : leftWidth;
            VkExtent2D eyeExtent = { width: width, height: extent.height };

            VkViewport viewport = {
                x: cast(float) x,
                y: 0,
                width: cast(float) width,
                height: cast(float) extent.height,
                minDepth: 0,
                maxDepth: 1,
            };
            VkRect2D scissor = {
                offset: VkOffset2D(x: cast(int) x, y: 0),
                extent: eyeExtent,
            };

            vkCmdSetViewport(buf, 0, 1, &viewport);
            vkCmdSetScissor(buf, 0, 1, &scissor);

            if(transmission)
                drawScene(buf, eye, eyeExtent, DrawPhase.transmission);
            else
            {
                drawScene(buf, eye, eyeExtent, DrawPhase.surface);
                drawScene(buf, eye, eyeExtent, DrawPhase.blended);
            }
        }
    }

    /// Parallel stereo: left eye in the left half, right eye in the right half.
    /// Cross-eyed viewing needs the halves swapped.
    void recordStereoCommandBuffer(
        ref Frame frame,
        StereoDrawCallback drawScene,
        StereoDrawCallback drawTransmission = null,
        void delegate(ref VkCommandBuffer) drawShadow = null,
    )
    {
        auto commandBuffer = frame.commandBuffer;

        currentInstanceArena = instanceArenas[frameIndex(frame)];
        currentInstanceArena.reset();
        currentViewportHeight = cast(float) swapChain.imageExtent.height;
        // Each eye has its own frustum, so this path gathers nothing for the kernel
        currentCullFrame = null;

        transmissionPass = transmissionPassEnabled;
        oitPass = oitEnabled;

        recordShadow(frame, drawShadow);

        clearOit(frame);

        renderPass.recordCommandBuffer(
            commandBuffer,
            (ref VkCommandBuffer buf) { background.draw(buf, swapChain.imageExtent); },
            (ref VkCommandBuffer buf) { drawStereoEyes(buf, drawScene); },
        );

        if(oitEnabled)
            resolveOit(frame, false);

        if(transmissionPassEnabled)
        {
            // One copy serves both eyes: the fragment coordinate already carries
            // the viewport offset, so it lands in that eye's half
            copySceneColor(frame);

            renderPass.recordTransmissionCommandBuffer(
                commandBuffer,
                (ref VkCommandBuffer buf) {
                    if(drawTransmission !is null)
                        drawStereoEyes(buf, drawTransmission, true);
                },
            );

            if(oitEnabled)
            {
                resolveDepth(frame);
                resolveOit(frame, true);
            }
        }

        recordPendingScreenshot(frame);
        presentColor(frame);
    }

    private size_t frameIndex(ref Frame frame)
    {
        foreach(i, f; swapChain.frames)
            if(f is frame)
                return i;

        assert(false, "frame does not belong to the swapchain");
    }

    /// Renders the sun's view of the opaque scene before the main pass
    private void recordShadow(ref Frame frame, void delegate(ref VkCommandBuffer) drawShadow)
    {
        sunShadow.record(frameIndex(frame), frame.commandBuffer, drawShadow);
    }

    /// Empties the per-pixel lists before the opaque and blended draws fill them
    private void clearOit(ref Frame frame)
    {
        if(!oitEnabled)
            return;

        oitFrames[frameIndex(frame)].recordClear(frame.commandBuffer);
    }

    /// Blends the fragments each pixel collected, after every other pass wrote colour
    private void resolveOit(ref Frame frame, bool filterDepth)
    {
        if(!oitEnabled)
            return;

        auto oit = oitFrames[frameIndex(frame)];
        auto cb = frame.commandBuffer;
        const extent = swapChain.imageExtent;

        // Fragments written by the passes above must be visible to the resolve
        VkMemoryBarrier fragmentBarrier = {
            sType: VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            srcAccessMask: VK_ACCESS_SHADER_WRITE_BIT,
            dstAccessMask: VK_ACCESS_SHADER_READ_BIT,
        };

        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 1, &fragmentBarrier, 0, null, 0, null);

        VkRenderPassBeginInfo renderPassInfo = {
            sType: VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            renderPass: oitResolve.pass.vkRenderPass,
            framebuffer: oit.renderedFrameBuffer,
            renderArea: VkRect2D(
                offset: VkOffset2D(0, 0),
                extent: extent,
            ),
        };

        vkCmdBeginRenderPass(cb, &renderPassInfo, VK_SUBPASS_CONTENTS_INLINE);

        VkViewport viewport = {
            x: 0.0f,
            y: 0.0f,
            width: cast(float) extent.width,
            height: cast(float) extent.height,
            minDepth: 0.0f,
            maxDepth: 1.0f,
        };
        VkRect2D scissor = {
            offset: VkOffset2D(0, 0),
            extent: extent,
        };

        vkCmdSetViewport(cb, 0, 1, &viewport);
        vkCmdSetScissor(cb, 0, 1, &scissor);

        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, oitResolve.pipeline.graphicsPipeline);

        VkDescriptorSet frameSet = frame.frameSets[0].descriptorSet;
        vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS,
            oitResolve.pipeline.pipelineLayout, 1, 1, &frameSet, 0, null);

        uint filterValue = filterDepth ? 1 : 0;
        vkCmdPushConstants(cb, oitResolve.pipeline.pipelineLayout, VK_SHADER_STAGE_FRAGMENT_BIT,
            0, uint.sizeof, &filterValue);

        vkCmdDraw(cb, 3, 1, 0, 0);

        vkCmdEndRenderPass(cb);
    }

    /// Writes the nearest depth of the multisampled surface, glass included
    private void resolveDepth(ref Frame frame)
    {
        auto oit = oitFrames[frameIndex(frame)];
        auto cb = frame.commandBuffer;

        imageBarrier(
            cb, frame.depthBuf.depthImage.image,
            VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
            VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
            VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            VK_ACCESS_SHADER_READ_BIT,
            0, 1, VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT,
        );

        depthResolve.pass.record(cb, oit.renderedSceneDepthFrameBuffer, swapChain.imageExtent, (ref VkCommandBuffer buf) {
            vkCmdBindPipeline(buf, VK_PIPELINE_BIND_POINT_GRAPHICS, depthResolve.pipeline.graphicsPipeline);

            VkDescriptorSet frameSet = frame.frameSets[0].descriptorSet;
            vkCmdBindDescriptorSets(buf, VK_PIPELINE_BIND_POINT_GRAPHICS,
                depthResolve.pipeline.pipelineLayout, 1, 1, &frameSet, 0, null);

            vkCmdDraw(buf, 3, 1, 0, 0);
        });
    }

    void recreateSwapChain()
    {
        if(swapChain.isOffscreen())
            return;

        swapChain = new SwapChain(device, frameBuilder, surface, renderPass, swapChain, surfaceFormat.colorSpace, presentMode);
        createFrameSets();
    }

    /// Saves the next rendered frame to a PNG
    void captureFrame(string path)
    {
        pendingScreenshotPath = path;
    }

    private void recordPendingScreenshot(ref Frame frame)
    {
        if(pendingScreenshotPath.length == 0)
            return;

        if(pendingScreenshot is null)
            pendingScreenshot = new Screenshot(
                device,
                swapChain.imageExtent.width,
                swapChain.imageExtent.height,
                swapChain.imageFormat,
            );

        pendingScreenshot.record(frame.commandBuffer, frame.image);
    }

    void drawNextFrame(void delegate(ref FrameBuilder fb, ref Frame frame) dg)
    {
        import pukan.exceptions: PukanExceptionWithCode;

        static if(pipelineWarmupEnabled)
        {
            if(!pipelinesReady)
            {
                pipelineFactory.waitForRequests();
                pipelinesReady = true;
            }
        }

        swapChain.oldSwapchainsMaintenance();

        uint imageIndex;

        {
            auto ret = swapChain.acquireNextImage(imageIndex);

            if(ret == VK_ERROR_OUT_OF_DATE_KHR)
            {
                recreateSwapChain();
                return;
            }
            else
            {
                if(ret != VK_SUCCESS && ret != VK_SUBOPTIMAL_KHR)
                    throw new PukanExceptionWithCode(ret, "failed to acquire swap chain image");
            }
        }

        auto frame = swapChain.frames[imageIndex];

        frame.commandBuffer.beginOneTimeCommandBuffer;
        dg(frameBuilder, frame);
        frame.commandBuffer.endCommandBuffer;

        {
            frameBuilder.placeDrawnFrameToGraphicsQueue(frame, !swapChain.isOffscreen());

            auto ret = swapChain.queueImageForPresentation(frame, imageIndex);

            if (ret == VK_ERROR_OUT_OF_DATE_KHR || ret == VK_SUBOPTIMAL_KHR)
            {
                windowSizeChanged();
                recreateSwapChain();
                return;
            }
            else
            {
                if(ret != VK_SUCCESS)
                    throw new PukanExceptionWithCode(ret, "failed to queue image for presentation");
            }
        }

        if(pendingScreenshot !is null)
        {
            vkDeviceWaitIdle(device.device);
            pendingScreenshot.save(pendingScreenshotPath);
            lastScreenshotPath = pendingScreenshotPath;
            pendingScreenshotPath = null;
            destroy(pendingScreenshot);
            pendingScreenshot = null;
        }

        swapChain.toNextFrame();
    }
}

/// Scene with the built-in PBR variants, warmed automatically for required
alias Scene = SceneWith!();

import dlib.math;

///
struct WorldTransformation
{
    Matrix4f model; /// model to World
    Matrix4f view; /// World to view (to camera)
    Matrix4f proj; /// view to projection (to projective/homogeneous coordinates)
}

enum maxLights = 16;

enum LightType : uint
{
    directional,
    point,
    spot,
}

/// Mirrors the Light struct in frame.glsl
struct Light
{
    Vector4f positionRadius;    // point/spot: xyz = world position, w = radius; directional: xyz = direction
    Vector4f directionOuterCos; // spot: xyz = beam direction, w = cosine of the outer angle
    Vector4f colorIntensity;    // rgb = colour, already scaled by intensity
    Vector4f params;            // x = type, y = cosine of the inner angle
}

static assert(Light.sizeof == 64);

struct FrameUniforms
{
    Matrix4x4f invViewProj;
    Matrix4x4f viewProj;
    Matrix4x4f shadowViewProj;
    Vector4f cameraPosition;
    Vector4f exposureParams; // x = exposure, y = IBL intensity, z = scene colour, w = light count
    Vector4f shadowParams;   // x = 1 while the sun's shadow map is used
    Vector4f ambientParams;  // rgb = ambient tint, a = ambient energy
    Vector4f tonemapParams;  // x = mode, y = white
}

///
struct Vertex {
    Vector3f pos;
    Vector3f color;
    Vector2f texCoord;
};
