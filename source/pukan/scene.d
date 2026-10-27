module pukan.scene;

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

    VkQueue graphicsQueue;
    VkQueue presentQueue;

    import pukan.primitives_tree: PrimitivesFactory;
    PipelineFactory pipelineFactory;
    MeshResources meshResources;
    PrimitivesFactory!ColoredMesh coloredMeshFactory;
    PrimitivesFactory!(pukan.primitives_tree.mesh.TexturedMesh) texturedMeshFactory;
    GltfFactory gltfFactory;
    SphereRenderer sphereRenderer;
    CylinderRenderer cylinderRenderer;

    this(LogicalDevice dev, VkSurfaceKHR surf, WindowSizeChangeDetectedCallback wsc)
    {
        device = dev;
        surface = surf;
        windowSizeChanged = wsc;

        device.physicalDevice.instance.useSurface(surface);

        renderPass = device.create!DefaultRenderPass(VK_FORMAT_B8G8R8A8_SRGB);

        pipelineFactory = new PipelineFactory(device);
        meshResources = new MeshResources(device);

        background = new Checkerboard(device, pipelineFactory, renderPass);

        frameBuilder = device.create!FrameBuilder(WorldTransformation.sizeof);
        swapChain = new SwapChain(device, frameBuilder, surface, renderPass, null);

        coloredMeshFactory = PrimitivesFactory!ColoredMesh(device, pipelineFactory, meshResources, renderPass);
        texturedMeshFactory = PrimitivesFactory!TexturedMesh(device, pipelineFactory, meshResources, renderPass);
        gltfFactory = new GltfFactory(device, pipelineFactory, meshResources, renderPass);
        sphereRenderer = new SphereRenderer(device, pipelineFactory, renderPass);
        cylinderRenderer = new CylinderRenderer(device, pipelineFactory, renderPass);
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
        swapChain = new SwapChain(device, frameBuilder, surface, renderPass, swapChain);
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

///
struct Vertex {
    Vector3f pos;
    Vector3f color;
    Vector2f texCoord;

    static auto getBindingDescriptions() {
        return [
            VkVertexInputBindingDescription(
                binding: 0,
                stride: this.sizeof,
                inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
            ),
        ];
    }

    static auto getAttributeDescriptions()
    {
        VkVertexInputAttributeDescription[3] ad;

        ad[0] = VkVertexInputAttributeDescription(
            binding: 0,
            location: 0,
            format: VK_FORMAT_R32G32B32_SFLOAT,
            offset: pos.offsetof,
        );

        ad[1] = VkVertexInputAttributeDescription(
            binding: 0,
            location: 1,
            format: VK_FORMAT_R32G32B32_SFLOAT,
            offset: color.offsetof,
        );

        ad[2] = VkVertexInputAttributeDescription(
            binding: 0,
            location: 2,
            format: VK_FORMAT_R32G32_SFLOAT,
            offset: texCoord.offsetof,
        );

        return ad;
    }
};
