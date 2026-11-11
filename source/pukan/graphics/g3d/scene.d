module pukan.graphics.g3d.scene;

import dlib.math: translation, Matrix4x4f, Vector3f, Vector4f;
import pukan;
import pukan.graphics.common.frame_bindings: frameBindings, frameSetBindings;
import pukan.graphics.common.frame_pacer: FramePacer;
import pukan.graphics.g3d.cells: CellGrid;
import pukan.graphics.common.screenshot: Screenshot;
import pukan.graphics.g2d.ui: Ui;
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
import pukan.graphics.g3d.camera: cameraView, vulkanPerspectiveMatrix;
import pukan.graphics.g3d.shadow: LocalShadow, SunCascades, SunShadow, localShadowCount, localTileSize, localTilesPerAxis, sunCascadeCount;
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

    /// Upper bound on frames per second; zero leaves pacing to the present mode
    @property double frameRateLimit() const => pacer.fps;
    /// A new rate restarts the schedule, so the next frame starts without delay
    @property void frameRateLimit(double value) => pacer.fps = value;

    VkQueue graphicsQueue;
    VkQueue presentQueue;

    import pukan.graphics.g3d.primitives_tree: PrimitivesFactory;
    PipelineFactory pipelineFactory;
    /// Persists driver pipeline caches between runs, null when none is configured
    PipelineCacheStore pipelineCacheStore;
    /// Shared by the factory and the compute kernels, null with no store
    PipelineCacheManager pipelineCacheManager;
    /// Debug windows drawn over the frame, null until enabled
    Ui ui;
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
    /// The spot lights' shadow atlas and its cache
    LocalShadow localShadow;
    /// Spot lights the atlas held last frame, to notice a change of choice
    private uint[localShadowCount] localAssignment;
    private uint localAssignmentCount;
    private VkObj!VkSampler resolveSampler;
    private OitResolve oitResolve;
    private DepthResolve depthResolve;
    /// OIT images of the current swapchain, indexed like its frames
    private OitFrame[] oitFrames;
    /// OIT images of the current swapchain; released before its frame sets go
    private ResourceOwner!false oitOwner;
    /// Set after the first frame has waited for the preload queue
    private bool pipelinesReady;
    private FramePacer pacer;

    float exposure = 1.0f;
    float iblIntensity = 1.0f;
    /// Ambient tint and energy applied to the IBL term
    Vector4f ambientLight = Vector4f(1, 1, 1, 1);
    /// Godot tonemap mode: linear, Reinhard, Filmic, ACES, AgX
    uint tonemapMode = 3;
    float tonemapWhite = 1.0f;
    /// Partition of the world that cells and streaming work from
    CellGrid cellGrid;

    /// Every light the level added, the sun first
    private Light[] candidates;
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

        candidates[0] = Light(
            Vector4f(dir.x, dir.y, dir.z, 0),
            Vector4f(0, 0, 0, 0),
            Vector4f(color.x * intensity, color.y * intensity, color.z * intensity, 0),
            Vector4f(cast(float) LightType.directional, 0, 0, 0),
        );

        sunShadow.invalidate();
    }

    /// Lights the level added, including the sun
    uint activeLightCount() const => cast(uint) candidates.length;

    /// Lights the last frame uploaded, after culling
    uint selectedLightCount() const => lightCount;

    private void addLight(Light light)
    {
        import std.exception: enforce;

        enforce(candidates.length < maxSceneLights, "too many lights");

        candidates ~= light;

        if(localShadow)
            localShadow.invalidate();
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
        candidates ~= Light(
            Vector4f(sun.x, sun.y, sun.z, 0),
            Vector4f(0, 0, 0, 0),
            Vector4f(1, 1, 1, 1),
            Vector4f(cast(float) LightType.directional, 0, 0, 0),
        );

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
        localShadow = new LocalShadow(device);

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

        coloredMeshFactory = PrimitivesFactory!ColoredMesh(device, pipelineFactory, meshResources,
            renderPass, sunShadow.pass);
        texturedMeshFactory = PrimitivesFactory!TexturedMesh(device, pipelineFactory, meshResources,
            renderPass, sunShadow.pass);
        litMeshFactory = PrimitivesFactory!LitMesh(device, pipelineFactory, meshResources,
            renderPass, sunShadow.pass);
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
        sphereRenderer = new SphereRenderer(device, pipelineFactory, renderPass,
            meshResources.fakeTexture, sunShadow.pass);
        cylinderRenderer = new CylinderRenderer(device, pipelineFactory, renderPass,
            meshResources.fakeTexture, sunShadow.pass);

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
        sceneOwner.own(localShadow);
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

        if(ui)
            destroy(ui);

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
        localShadow.recreate(swapChain.frames.length);

        foreach(ref frame; swapChain.frames)
            frame.sceneColor = createSceneColorTexture(swapChain.imageExtent);

        oitFrames = null;
        oitFrames.length = swapChain.frames.length;

        foreach(i, ref frame; swapChain.frames)
        {
            auto sceneColor = imageInfo(frame.sceneColor);

            lightBufs[i] = device.create!MemoryBufferMappedToCPU(maxLights * Light.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
            screenOwner.own(lightBufs[i]);

            auto shadowInfo0 = sunShadow.imageInfo(i, 0);
            auto shadowInfo1 = sunShadow.imageInfo(i, 1);
            auto shadowInfo2 = sunShadow.imageInfo(i, 2);
            auto localInfo = localShadow.imageInfo(i);
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
                    shadowInfo0,
                    shadowInfo1,
                    shadowInfo2,
                    sceneDepth,
                    depthMS,
                    localInfo,
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

        // The light matrices are only needed while the shadow pass runs
        if(sunShadow.enabled)
        {
            const sun = Vector3f(
                lights[0].positionRadius.x,
                lights[0].positionRadius.y,
                lights[0].positionRadius.z,
            );
            sunShadow.update(sun, camera, data.invViewProj);

            foreach(cascade; 0 .. sunCascadeCount)
                data.shadowViewProj[cascade] = sunShadow.cascades.viewProj[cascade];
        }

        data.shadowParams = Vector4f(
            sunShadow.enabled ? 1 : 0,
            sunShadow.cascades.depthBias[0],
            sunShadow.cascades.depthBias[1],
            sunShadow.cascades.depthBias[2],
        );
        data.shadowSplits = Vector4f(
            sunShadow.cascades.splitFar[0],
            sunShadow.cascades.splitFar[1],
            sunShadow.cascades.splitFar[2],
            SunCascades.blendBand,
        );
        data.ambientParams = ambientLight;
        data.tonemapParams = Vector4f(cast(float) tonemapMode, tonemapWhite, 0, 0);
        selectLights(camera, wtb.proj, swapChain.imageExtent.height);
        background.tonemapMode = tonemapMode;
        background.white = tonemapWhite;
        background.exposure = exposure;


        data.exposureParams = Vector4f(
            exposure,
            iblIntensity,
            transmissionPassEnabled ? 1 : 0,
            cast(float) lightCount,
        );

        assignLocalShadows(data, camera);

        auto lightBuffer = lightBufs[frameIndex(frame)];
        const lightBytes = lightCount * Light.sizeof;
        (cast(Light[]) lightBuffer.cpuBuf[0 .. lightBytes])[] = lights[0 .. lightCount];

        frame.frameSets[eye].update(data);
    }

    /// Fills the frame list with the sun and the local lights that cover the most pixels
    private void selectLights(in Vector3f camera, in Matrix4x4f proj, uint viewportHeight)
    {
        import std.algorithm: max, min, sort;
        import std.math: abs;

        struct Candidate
        {
            size_t index;
            float score;
        }

        Candidate[] locals;

        // The sun always keeps the first slot
        lights[0] = candidates[0];

        // Pixels a one-unit sphere covers at distance one
        const focal = abs(proj.a22) * viewportHeight * 0.5f;

        foreach(i; 1 .. candidates.length)
        {
            const light = candidates[i];
            const kind = cast(uint) light.params.x;

            if(kind != LightType.point && kind != LightType.spot)
                continue;

            const position = Vector3f(light.positionRadius.x, light.positionRadius.y, light.positionRadius.z);
            const range = max(light.positionRadius.w, 0.01f);
            const distance = max((position - camera).length, 0.01f);
            const pixels = range / distance * focal;

            if(pixels < 1.0f)
                continue;

            locals ~= Candidate(i, pixels);
        }

        locals.sort!((a, b) => a.score > b.score)();

        const take = min(locals.length, maxLights - 1);
        lightCount = 1 + cast(uint) take;

        foreach(i; 0 .. take)
            lights[1 + i] = candidates[locals[i].index];
    }

    /// Fits the shadowed local lights into tiles, nearest to the camera first
    private void assignLocalShadows(ref FrameUniforms data, in Vector3f camera)
    {
        import std.algorithm: clamp, max, sort;
        import std.math: PI, abs, acos;

        // A point light needs one tile per cube face
        enum pointTiles = 6;

        struct LocalCandidate
        {
            uint light;
            uint tiles;
            float distance;
        }

        LocalCandidate[] candidates;

        foreach(i; 0 .. lightCount)
        {
            ref light = lights[i];
            light.params.z = -1;
            light.params.w = 0;

            const kind = cast(uint) light.params.x;

            if(kind != LightType.spot && kind != LightType.point)
                continue;

            const position = Vector3f(light.positionRadius.x, light.positionRadius.y, light.positionRadius.z);
            candidates ~= LocalCandidate(
                cast(uint) i,
                kind == LightType.point ? pointTiles : 1,
                (position - camera).length,
            );
        }

        candidates.sort!((a, b) => a.distance < b.distance)();

        // Nearest first; a light whose tiles do not fit stays unshadowed
        LocalCandidate[] chosen;
        uint needed;

        foreach(candidate; candidates)
            if(needed + candidate.tiles <= localShadowCount)
            {
                chosen ~= candidate;
                needed += candidate.tiles;
            }

        uint[localShadowCount] next;
        next[] = uint.max;

        uint used;

        foreach(candidate; chosen)
            foreach(_; 0 .. candidate.tiles)
                next[used++] = candidate.light;

        bool changed = localAssignmentCount != needed;

        foreach(tile; 0 .. localShadowCount)
            if(localAssignment[tile] != next[tile])
                changed = true;

        if(changed)
        {
            localShadow.invalidate();
            localAssignment = next;
            localAssignmentCount = needed;
        }

        uint tile;

        foreach(candidate; chosen)
        {
            ref light = lights[candidate.light];
            const position = Vector3f(light.positionRadius.x, light.positionRadius.y, light.positionRadius.z);
            const radius = max(light.positionRadius.w, 0.1f);

            if(cast(uint) light.params.x == LightType.spot)
            {
                const direction = Vector3f(
                    light.directionOuterCos.x,
                    light.directionOuterCos.y,
                    light.directionOuterCos.z,
                ).normalized;
                const outer = acos(clamp(light.directionOuterCos.w, -1.0f, 1.0f));
                const up = abs(direction.y) > 0.99f ? Vector3f(0, 0, 1) : Vector3f(0, 1, 0);

                const view = cameraView(position, position + direction, up);
                const fov = clamp(outer * 2.0f * 180.0f / PI, 0.01f, 179.0f);
                const proj = vulkanPerspectiveMatrix(fov, 1.0f, 0.05f, radius);

                localShadow.viewProj[tile] = proj * view;
                localShadow.depthBias[tile] = 0.03f / radius;
                light.shadowViewProj[0] = localShadow.viewProj[tile];
                light.params.z = cast(float) tile;
                light.params.w = localShadow.depthBias[tile];

                ++tile;
                continue;
            }

            const proj = vulkanPerspectiveMatrix(90.0f, 1.0f, 0.05f, radius);
            const bias = 0.03f / radius;

            light.params.z = cast(float) tile;
            light.params.w = bias;

            foreach(face; 0 .. 6)
            {
                const view = cameraView(position, position + faceDirection(face), faceUp(face));
                localShadow.viewProj[tile] = proj * view;
                localShadow.depthBias[tile] = bias;
                light.shadowViewProj[face] = localShadow.viewProj[tile];

                ++tile;
            }
        }

        localShadow.active = tile;


        data.localShadowParams = Vector4f(
            1.0f / localTilesPerAxis,
            cast(float) localTilesPerAxis,
            1.0f / localTileSize,
            localShadow.enabled ? 1 : 0,
        );
    }

    /// Direction from a point light into one of its six shadow faces
    private static Vector3f faceDirection(uint face)
    {
        static immutable Vector3f[6] directions = [
            Vector3f(1, 0, 0), Vector3f(-1, 0, 0),
            Vector3f(0, 1, 0), Vector3f(0, -1, 0),
            Vector3f(0, 0, 1), Vector3f(0, 0, -1),
        ];

        return directions[face];
    }

    /// Up axis of one shadow face, so its map stays upright
    private static Vector3f faceUp(uint face)
    {
        static immutable Vector3f[6] ups = [
            Vector3f(0, 1, 0), Vector3f(0, 1, 0),
            Vector3f(0, 0, 1), Vector3f(0, 0, 1),
            Vector3f(0, 1, 0), Vector3f(0, 1, 0),
        ];

        return ups[face];
    }

    void recordCommandBuffer(
        ref Frame frame,
        SceneDrawCallback drawScene,
        SceneDrawCallback drawTransmission = null,
        ShadowDrawCallback drawShadow = null,
        LocalDrawCallback drawLocal = null,
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
        recordLocal(frame, drawLocal);

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

        if(ui !is null)
            ui.record(commandBuffer, frame.imageView, cast(uint) frameIndex(frame), swapChain.imageExtent);

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
    alias ShadowDrawCallback = void delegate(ref VkCommandBuffer, size_t cascade);
    alias LocalDrawCallback = void delegate(ref VkCommandBuffer, size_t tile);

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
        ShadowDrawCallback drawShadow = null,
        LocalDrawCallback drawLocal = null,
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

        if(ui !is null)
            ui.record(commandBuffer, frame.imageView, cast(uint) frameIndex(frame), swapChain.imageExtent);

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

    /// Creates the debug UI; call it before the first frame
    Ui enableUi()
    {
        if(ui is null)
            ui = new Ui(device, pipelineFactory, surfaceFormat.format);

        return ui;
    }

    /// Whether this frame still has to draw the cascade, so it can be culled first
    bool shadowPending(ref Frame frame, size_t cascade)
    {
        return sunShadow.pending(frameIndex(frame), cascade);
    }

    /// Whether this frame still has to draw the spots' atlas
    bool localPending(ref Frame frame)
    {
        return localShadow.pending(frameIndex(frame));
    }

    /// Renders the sun's view of the opaque scene before the main pass
    private void recordShadow(ref Frame frame, ShadowDrawCallback drawShadow)
    {
        sunShadow.record(frameIndex(frame), frame.commandBuffer, drawShadow);
    }

    /// Renders the shadowed spots into their atlas tiles before the main pass
    private void recordLocal(ref Frame frame, LocalDrawCallback drawLocal)
    {
        localShadow.record(frameIndex(frame), frame.commandBuffer, drawLocal);
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
            0, 1, VK_IMAGE_ASPECT_DEPTH_BIT,
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

        pacer.waitNextFrame();

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
        pipelineFactory.beginFrame(frameIndex(frame));

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
/// Lights a level may add; the frame keeps the most visible ones
enum maxSceneLights = 256;

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
    Vector4f params;            // x = type, y = cosine of the inner angle, z = shadow tile, w = bias
    Matrix4x4f[6] shadowViewProj; // spot: face 0; point: the six cube faces
}

static assert(Light.sizeof == 448);

struct FrameUniforms
{
    Matrix4x4f invViewProj;
    Matrix4x4f viewProj;
    Matrix4x4f[sunCascadeCount] shadowViewProj;
    Vector4f cameraPosition;
    Vector4f exposureParams; // x = exposure, y = IBL intensity, z = scene colour, w = light count
    Vector4f shadowParams;   // x = 1 while the sun's shadow map is used, yzw = depth bias per cascade
    Vector4f shadowSplits;   // xyz = far view depth of each cascade
    Vector4f localShadowParams; // x = 1/tiles, y = tiles, z = 1/tile size
    Vector4f ambientParams;  // rgb = ambient tint, a = ambient energy
    Vector4f tonemapParams;  // x = mode, y = white
}

///
struct Vertex {
    Vector3f pos;
    Vector3f color;
    Vector2f texCoord;
};
