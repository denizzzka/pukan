module pukan.scene;

import dlib.math: perspectiveMatrix, translation, Matrix4x4f, Vector3f, Vector4f;
import pukan;
import pukan.pbr.pipelines: oitPass, transmissionPass;
import pukan.ibl: createIblTextures, IblTextures;
import pukan.mesh: MeshResources;
import pukan.oit: DepthResolve, OitFrame, OitResolve;
import pukan.pbr.instancing: InstanceArena, currentInstanceArena;
import pukan.screenshot: Screenshot;
import pukan.shadow: ShadowMap, ShadowPass;
import pukan.primitives_tree.cylinder: CylinderRenderer;
import pukan.primitives_tree.sphere: SphereRenderer;
import pukan.vulkan;
import pukan.vulkan.bindings;

/// Transform of a camera placed at `eye` and looking at `target`
Matrix4x4f cameraTransform(Vector3f eye, Vector3f target, Vector3f up)
{
    import dlib.math: cross;
    import std.math: abs;

    const forward = (target - eye).normalized;
    auto realUp = up;

    // A view parallel to the up axis has no right axis, so any other axis serves
    if(cross(forward, realUp).length < 1e-6f)
        realUp = abs(forward.y) > 0.9f ? Vector3f(0, 0, 1) : Vector3f(0, 1, 0);

    const right = cross(forward, realUp).normalized;
    realUp = cross(right, forward);

    Matrix4x4f result = Matrix4x4f.identity;
    // Each column is a world axis of the camera
    result.a11 = right.x;    result.a21 = right.y;    result.a31 = right.z;
    result.a12 = realUp.x;   result.a22 = realUp.y;   result.a32 = realUp.z;
    result.a13 = -forward.x; result.a23 = -forward.y; result.a33 = -forward.z;
    result.a14 = eye.x;      result.a24 = eye.y;      result.a34 = eye.z;
    return result;
}

/// View matrix of a camera whose -Z axis points at `target`
Matrix4x4f cameraView(Vector3f eye, Vector3f target, Vector3f up)
{
    return cameraTransform(eye, target, up).inverse;
}

unittest
{
    import dlib.math: lookAtMatrix;
    import std.math: abs;

    const eye = Vector3f(3, 4, -5);
    const target = Vector3f(0, 1, 0);
    const up = Vector3f(0, 1, 0);

    // The inverse of the camera transform matches dlib for a normal view
    const expected = lookAtMatrix(eye, target, up);
    const view = cameraView(eye, target, up);

    foreach(i; 0 .. 16)
        assert(abs(view.arrayof[i] - expected.arrayof[i]) < 1e-5f);

    // A view along the up axis must not assert and still give an orthonormal basis
    const vertical = cameraView(Vector3f(0, 10, 0), Vector3f(0, 0, 0), up);
    const x = Vector3f(vertical.a11, vertical.a12, vertical.a13);
    const y = Vector3f(vertical.a21, vertical.a22, vertical.a23);

    assert(abs(x.length - 1) < 1e-5f);
    assert(abs(y.length - 1) < 1e-5f);
    assert(abs(x.dot(y)) < 1e-5f);
}

unittest
{
    import dlib.math: rotationQuaternion;

    // Approaching the pole must keep the roll instead of snapping to another up
    const worldUp = Vector3f(0, 1, 0);
    const a = Vector3f(0.05f, 1, 0).normalized;
    const b = Vector3f(0.042f, 1, 0).normalized;

    const viewA = cameraTransform(Vector3f(0, 0, 0), a,
        rotationQuaternion(a, 0.7f).rotate(worldUp));
    const viewB = cameraTransform(Vector3f(0, 0, 0), b,
        rotationQuaternion(b, 0.7f).rotate(worldUp));

    const upA = Vector3f(viewA.a12, viewA.a22, viewA.a32);
    const upB = Vector3f(viewB.a12, viewB.a22, viewB.a32);

    assert(upA.dot(upB) > 0.99f);
}

/// Perspective projection for Vulkan, whose clip space has Y pointing down,
/// unlike the OpenGL convention that dlib builds
Matrix4x4f vulkanPerspectiveMatrix(float fovY, float aspectRatio, float nearPlane, float farPlane)
{
    auto result = perspectiveMatrix(fovY, aspectRatio, nearPlane, farPlane);
    result.a22 = -result.a22;
    return result;
}

class Scene
{
    LogicalDevice device;
    VkSurfaceKHR surface;
    VkSurfaceFormatKHR surfaceFormat;

    alias WindowSizeChangeDetectedCallback = void delegate();
    WindowSizeChangeDetectedCallback windowSizeChanged;

    SwapChain swapChain;
    FrameBuilder frameBuilder;
    DefaultRenderPass renderPass; //TODO: replace by RenderPass base?
    Checkerboard background;
    VkPresentModeKHR presentMode;

    VkQueue graphicsQueue;
    VkQueue presentQueue;

    import pukan.primitives_tree: PrimitivesFactory;
    PipelineFactory pipelineFactory;
    private DescriptorAllocator frameAllocator;
    MeshResources meshResources;
    PrimitivesFactory!ColoredMesh coloredMeshFactory;
    PrimitivesFactory!(pukan.primitives_tree.mesh.TexturedMesh) texturedMeshFactory;
    PrimitivesFactory!(pukan.primitives_tree.mesh.LitMesh) litMeshFactory;
    GltfFactory gltfFactory;
    GodotFactory godotFactory;
    PbrFactory pbrFactory;
    SphereRenderer sphereRenderer;
    CylinderRenderer cylinderRenderer;
    IblTextures ibl;

    /// Blended draws store their fragments in per-pixel lists this resolves
    bool oitEnabled = true;

    private Screenshot pendingScreenshot;
    private string pendingScreenshotPath;
    /// Path of the frame saved by the last `captureFrame` call
    string lastScreenshotPath;

    /// The sun casts a shadow map before the main pass
    bool shadowsEnabled = true;
    /// Render the sun's view once and reuse it until invalidated
    bool shadowMapCache;
    enum shadowMapSize = 1024;
    enum shadowFov = 24.0f;
    enum shadowDistance = 10.0f;
    /// Light view-projection the shadow map and the PBR sampling share
    Matrix4x4f shadowViewProj;
    private ShadowPass shadowPass;
    private ShadowMap[] shadowMaps;
    private bool[] shadowMapValid;
    private VkSampler shadowSampler;
    private VkSampler resolveSampler;
    private OitResolve oitResolve;
    private DepthResolve depthResolve;
    private OitFrame[] oitFrames;
    /// Lists of a replaced swapchain, kept until its commands are done
    private OitFrame[][] retiredOitFrames;
    private uint framesSinceOitRetire;

    float exposure = 1.0f;
    float iblIntensity = 1.0f;
    /// Uploaded with the frame; the first entry is the sun
    private Light[maxLights] lights;
    private uint lightCount;
    private MemoryBufferMappedToCPU[] lightBufs;
    private InstanceArena[] instanceArenas;

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

        invalidateShadowMap();
    }

    /// Renders the sun's view again on the next frame; call it after moving casters
    void invalidateShadowMap()
    {
        shadowMapValid[] = false;
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
        VkPresentModeKHR presentMode = VK_PRESENT_MODE_FIFO_KHR,
    )
    {
        device = dev;
        surface = surf;
        windowSizeChanged = wsc;
        this.surfaceFormat = surfaceFormat;
        this.presentMode = presentMode;

        const sun = Vector3f(0.35f, 0.5f, -0.8f).normalized;
        lights[0] = Light(
            Vector4f(sun.x, sun.y, sun.z, 0),
            Vector4f(0, 0, 0, 0),
            Vector4f(1, 1, 1, 1),
            Vector4f(cast(float) LightType.directional, 0, 0, 0),
        );
        lightCount = 1;

        device.physicalDevice.instance.useSurface(surface);

        renderPass = device.create!DefaultRenderPass(surfaceFormat.format);

        pipelineFactory = new PipelineFactory(device);
        frameAllocator = pipelineFactory.createFrameAllocator();
        meshResources = new MeshResources(device);
        ibl = createIblTextures(device);

        background = new Checkerboard(device, pipelineFactory, renderPass);

        oitResolve = new OitResolve(device, pipelineFactory, surfaceFormat.format);
        depthResolve = new DepthResolve(device, pipelineFactory);

        shadowPass = new ShadowPass(device, DefaultRenderPass.depthFormat);

        {
            VkSamplerCreateInfo samplerInfo = {
                sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                magFilter: VK_FILTER_LINEAR,
                minFilter: VK_FILTER_LINEAR,
                mipmapMode: VK_SAMPLER_MIPMAP_MODE_NEAREST,
                addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                compareEnable: VK_TRUE,
                compareOp: VK_COMPARE_OP_LESS_OR_EQUAL,
                borderColor: VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE,
                unnormalizedCoordinates: VK_FALSE,
            };
            vkCall(device.device, &samplerInfo, device.alloc, &shadowSampler);
        }

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
            vkCall(device.device, &samplerInfo, device.alloc, &resolveSampler);
        }

        frameBuilder = device.create!FrameBuilder(WorldTransformation.sizeof);
        swapChain = new SwapChain(device, frameBuilder, surface, renderPass, null, surfaceFormat.colorSpace, presentMode);
        createFrameSets();

        coloredMeshFactory = PrimitivesFactory!ColoredMesh(device, pipelineFactory, meshResources, renderPass);
        texturedMeshFactory = PrimitivesFactory!TexturedMesh(device, pipelineFactory, meshResources, renderPass);
        litMeshFactory = PrimitivesFactory!LitMesh(device, pipelineFactory, meshResources, renderPass);
        pbrFactory = new PbrFactory(device, pipelineFactory, meshResources, renderPass, shadowPass);
        gltfFactory = new GltfFactory(pbrFactory);
        godotFactory = new GodotFactory(pbrFactory, gltfFactory);
        sphereRenderer = new SphereRenderer(device, pipelineFactory, renderPass, meshResources.fakeTexture);
        cylinderRenderer = new CylinderRenderer(device, pipelineFactory, renderPass, meshResources.fakeTexture);
    }

    ~this()
    {
        if(pendingScreenshot)
            destroy(pendingScreenshot);

        gltfFactory.destroyAssets();

        background.destroy;

        foreach(ref batch; retiredOitFrames)
            foreach(ref oit; batch)
                if(oit)
                    destroy(oit);

        foreach(ref oit; oitFrames)
            if(oit)
                destroy(oit);

        foreach(ref buffer; lightBufs)
            if(buffer)
                destroy(buffer);

        foreach(ref arena; instanceArenas)
            if(arena)
                destroy(arena);

        foreach(ref map; shadowMaps)
            if(map)
                destroy(map);

        if(shadowSampler)
            vkDestroySampler(device.device, shadowSampler, device.alloc);

        if(resolveSampler)
            vkDestroySampler(device.device, resolveSampler, device.alloc);

        if(shadowPass)
            destroy(shadowPass);

        if(depthResolve)
            destroy(depthResolve);

        if(oitResolve)
            destroy(oitResolve);

        // swapChain.frames should be destroyed before frameBuider
        swapChain.destroy;
        frameBuilder.destroy;

        if(godotFactory)
            destroy(godotFactory);

        if(gltfFactory)
            destroy(gltfFactory);

        if(pbrFactory)
            destroy(pbrFactory);

        if(ibl.brdfLut)
            destroy(ibl.brdfLut);

        if(ibl.prefiltered)
            destroy(ibl.prefiltered);

        if(ibl.irradiance)
            destroy(ibl.irradiance);

        if(meshResources)
            destroy(meshResources);
    }

    private void createFrameSets()
    {
        shadowMapValid.length = swapChain.frames.length;
        shadowMapValid[] = false;

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

        if(oitFrames.length)
        {
            retiredOitFrames ~= oitFrames;
            framesSinceOitRetire = 0;
        }
        oitFrames = null;

        foreach(ref buffer; lightBufs)
            if(buffer)
                destroy(buffer);
        lightBufs.length = swapChain.frames.length;

        foreach(ref arena; instanceArenas)
            if(arena)
                destroy(arena);
        instanceArenas.length = swapChain.frames.length;
        foreach(i; 0 .. instanceArenas.length)
            instanceArenas[i] = new InstanceArena(device);

        // The maps do not depend on the swapchain, so a replacement keeps them
        if(shadowMaps.length != swapChain.frames.length)
        {
            foreach(ref map; shadowMaps)
                if(map)
                    destroy(map);

            shadowMaps.length = swapChain.frames.length;
        }

        foreach(ref frame; swapChain.frames)
            frame.sceneColor = createSceneColorTexture(swapChain.imageExtent);

        oitFrames.length = swapChain.frames.length;

        foreach(i, ref frame; swapChain.frames)
        {
            auto sceneColor = imageInfo(frame.sceneColor);

            lightBufs[i] = device.create!MemoryBufferMappedToCPU(maxLights * Light.sizeof, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);

            shadowMaps[i] = new ShadowMap(device, shadowPass, shadowMapSize);
            auto shadowInfo = shadowMaps[i].imageInfo(shadowSampler);
            auto lightInfo = VkDescriptorBufferInfo(
                buffer: lightBufs[i].buf,
                offset: 0,
                range: maxLights * Light.sizeof,
            );

            oitFrames[i] = new OitFrame(device, oitResolve.pass, depthResolve.pass, frame.imageView, swapChain.imageExtent);

            auto oitHeads = oitFrames[i].headsImageInfo;
            auto oitFragments = oitFrames[i].fragmentsInfo;
            auto oitCounter = oitFrames[i].counterInfo;
            auto sceneDepth = oitFrames[i].sceneDepthInfo();
            sceneDepth.sampler = resolveSampler;

            auto depthMS = VkDescriptorImageInfo(
                imageLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
                imageView: frame.depthBuf.depthView,
                sampler: resolveSampler,
            );

            foreach(eye; 0 .. 2)
                frame.frameSets[eye] = new FrameSet(
                    device,
                    frameAllocator,
                    FrameUniforms.sizeof,
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
        if(shadowsEnabled)
        {
            const sun = Vector3f(
                lights[0].positionRadius.x,
                lights[0].positionRadius.y,
                lights[0].positionRadius.z,
            ).normalized;

            const shadowEye = sun * shadowDistance;
            const shadowView = cameraView(shadowEye, Vector3f(0, 0, 0), Vector3f(0, 1, 0));
            const shadowProj = vulkanPerspectiveMatrix(shadowFov, 1.0f, 1.0f, shadowDistance * 2.0f);
            shadowViewProj = shadowProj * shadowView;
            data.shadowViewProj = shadowViewProj;
        }

        data.shadowParams = Vector4f(shadowsEnabled ? 1 : 0, 0, 0, 0);
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
    )
    {
        auto commandBuffer = frame.commandBuffer;

        currentInstanceArena = instanceArenas[frameIndex(frame)];
        currentInstanceArena.reset();

        transmissionPass = transmissionPassEnabled;
        oitPass = oitEnabled;

        recordShadow(frame, drawShadow);

        clearOit(frame);

        renderPass.recordCommandBuffer(
            commandBuffer,
            (ref VkCommandBuffer buf) { background.draw(buf); },
            (ref VkCommandBuffer buf) {
                drawScene(buf, DrawPhase.surface);
                drawScene(buf, DrawPhase.blended);
            },
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

        transmissionPass = transmissionPassEnabled;
        oitPass = oitEnabled;

        recordShadow(frame, drawShadow);

        clearOit(frame);

        renderPass.recordCommandBuffer(
            commandBuffer,
            (ref VkCommandBuffer buf) { background.draw(buf); },
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

    /// Drops a replaced swapchain's lists after its commands have completed
    private void retireOitFrames()
    {
        if(retiredOitFrames.length == 0)
            return;

        if(++framesSinceOitRetire < SwapChain.oldSwapchainFrames)
            return;

        foreach(ref batch; retiredOitFrames)
            foreach(ref oit; batch)
                if(oit)
                    destroy(oit);

        retiredOitFrames = null;
        framesSinceOitRetire = 0;
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
        if(!shadowsEnabled || drawShadow is null)
            return;

        const index = frameIndex(frame);

        if(shadowMapCache && shadowMapValid[index])
            return;

        auto map = shadowMaps[index];
        shadowPass.record(frame.commandBuffer, map.renderedFrameBuffer, map.renderExtent, drawShadow);
        shadowMapValid[index] = true;
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

        retireOitFrames();

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
            frameBuilder.placeDrawnFrameToGraphicsQueue(frame);

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
}

///
struct Vertex {
    Vector3f pos;
    Vector3f color;
    Vector2f texCoord;
};
