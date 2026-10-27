module pukan.scene;

import dlib.math: translation, Vector3f, Vector4f;
import pukan;
import pukan.mesh: MeshResources;
import pukan.primitives_tree.cylinder: CylinderRenderer;
import pukan.primitives_tree.sphere: SphereRenderer;
import pukan.vulkan;
import pukan.vulkan.bindings;

class Scene
{
    LogicalDevice device;
    VkSurfaceKHR surface;

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
    SphereRenderer sphereRenderer;
    CylinderRenderer cylinderRenderer;

    this(
        LogicalDevice dev,
        VkSurfaceKHR surf,
        WindowSizeChangeDetectedCallback wsc,
        VkPresentModeKHR presentMode = VK_PRESENT_MODE_FIFO_KHR,
    )
    {
        device = dev;
        surface = surf;
        windowSizeChanged = wsc;
        this.presentMode = presentMode;

        device.physicalDevice.instance.useSurface(surface);

        renderPass = device.create!DefaultRenderPass(VK_FORMAT_B8G8R8A8_SRGB);

        pipelineFactory = new PipelineFactory(device);
        frameAllocator = pipelineFactory.createFrameAllocator();
        meshResources = new MeshResources(device);

        background = new Checkerboard(device, pipelineFactory, renderPass);

        frameBuilder = device.create!FrameBuilder(WorldTransformation.sizeof);
        swapChain = new SwapChain(device, frameBuilder, surface, renderPass, null, presentMode);
        createFrameSets();

        coloredMeshFactory = PrimitivesFactory!ColoredMesh(device, pipelineFactory, meshResources, renderPass);
        texturedMeshFactory = PrimitivesFactory!TexturedMesh(device, pipelineFactory, meshResources, renderPass);
        litMeshFactory = PrimitivesFactory!LitMesh(device, pipelineFactory, meshResources, renderPass);
        gltfFactory = new GltfFactory(device, pipelineFactory, meshResources, renderPass);
        sphereRenderer = new SphereRenderer(device, pipelineFactory, renderPass, meshResources.fakeTexture);
        cylinderRenderer = new CylinderRenderer(device, pipelineFactory, renderPass, meshResources.fakeTexture);
    }

    ~this()
    {
        background.destroy;

        // swapChain.frames should be destroyed before frameBuider
        swapChain.destroy;
        frameBuilder.destroy;

        if(gltfFactory)
            destroy(gltfFactory);

        if(meshResources)
            destroy(meshResources);
    }

    private void createFrameSets()
    {
        foreach(ref frame; swapChain.frames)
            foreach(eye; 0 .. 2)
                frame.frameSets[eye] = new FrameSet(device, frameAllocator, FrameUniforms.sizeof);
    }

    void updateFrameUniforms(ref Frame frame, size_t eye, in WorldTransformation wtb)
    {
        const viewProj = wtb.proj * wtb.view;
        const camera = translation(wtb.view.inverse);
        const light = Vector3f(0.35f, 0.5f, 0.8f).normalized;

        FrameUniforms data;
        data.invViewProj = viewProj.inverse;
        data.cameraPosition = Vector4f(camera.x, camera.y, camera.z, 1);
        data.lightDirection = Vector4f(light.x, light.y, light.z, 0);
        data.lightColor = Vector4f(1, 1, 1, 1);

        frame.frameSets[eye].update(data);
    }

    void recordCommandBuffer(VkCommandBuffer commandBuffer, void delegate(ref VkCommandBuffer) drawScene)
    {
        renderPass.recordCommandBuffer(
            commandBuffer,
            (ref VkCommandBuffer buf) { background.draw(buf); },
            drawScene,
        );
    }

    alias StereoDrawCallback = void delegate(ref VkCommandBuffer, size_t eye, VkExtent2D eyeExtent);

    /// Parallel stereo: left eye in the left half, right eye in the right half.
    /// Cross-eyed viewing needs the halves swapped.
    void recordStereoCommandBuffer(VkCommandBuffer commandBuffer, StereoDrawCallback drawScene)
    {
        renderPass.recordCommandBuffer(
            commandBuffer,
            (ref VkCommandBuffer buf) { background.draw(buf); },
            (ref VkCommandBuffer buf) {
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

                    drawScene(buf, eye, eyeExtent);
                }
            },
        );
    }

    void recreateSwapChain()
    {
        swapChain = new SwapChain(device, frameBuilder, surface, renderPass, swapChain, presentMode);
        createFrameSets();
    }

    void drawNextFrame(void delegate(ref FrameBuilder fb, ref Frame frame) dg)
    {
        import pukan.exceptions: PukanExceptionWithCode;

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

struct FrameUniforms
{
    Matrix4x4f invViewProj;
    Vector4f cameraPosition;
    Vector4f lightDirection;
    Vector4f lightColor;
}

///
struct Vertex {
    Vector3f pos;
    Vector3f color;
    Vector2f texCoord;
};
