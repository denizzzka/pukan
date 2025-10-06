module pukan.scene;

import pukan;
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
    CommandPool commandPool;

    VkQueue graphicsQueue;
    VkQueue presentQueue;

    ShaderModule vertShader;
    ShaderModule fragShader;
    VkPipelineShaderStageCreateInfo[] shaderStages;

    DescriptorPool descriptorPool;
    VkDescriptorSet[] descriptorSets;

    DefaultPipelineInfoCreator pipelineInfoCreator;
    GraphicsPipelines graphicsPipelines;

    this(LogicalDevice dev, VkSurfaceKHR surf, VkDescriptorSetLayoutBinding[] descriptorSetLayoutBindings, WindowSizeChangeDetectedCallback wsc)
    {
        device = dev;
        surface = surf;
        windowSizeChanged = wsc;

        device.physicalDevice.instance.useSurface(surface);

        renderPass = device.create!DefaultRenderPass(VK_FORMAT_B8G8R8A8_SRGB);
        commandPool = device.createCommandPool();
        frameBuilder = device.create!FrameBuilder(WorldTransformationUniformBuffer.sizeof);
        swapChain = new SwapChain(device, frameBuilder, surface, renderPass, null);
        vertShader = device.create!ShaderModule("vert.spv");
        fragShader = device.create!ShaderModule("frag.spv");

        shaderStages = [
            vertShader.createShaderStageInfo(VK_SHADER_STAGE_VERTEX_BIT),
            fragShader.createShaderStageInfo(VK_SHADER_STAGE_FRAGMENT_BIT),
        ];

        descriptorPool = device.create!DescriptorPool(descriptorSetLayoutBindings);
        pipelineInfoCreator = new DefaultPipelineInfoCreator(device, descriptorPool.descriptorSetLayout, shaderStages);
        VkGraphicsPipelineCreateInfo[] infos = [pipelineInfoCreator.pipelineCreateInfo];
        graphicsPipelines = device.create!GraphicsPipelines(infos, renderPass);

        descriptorSets = descriptorPool.allocateDescriptorSets([descriptorPool.descriptorSetLayout]);
    }

    ~this()
    {
        destr(graphicsPipelines);
        destr(pipelineInfoCreator);
        destr(descriptorPool);
        destr(fragShader);
        destr(vertShader);
        destr(swapChain);
        destr(frameBuilder);
        destr(commandPool);
        destr(renderPass);
    }

    void recreateSwapChain()
    {
        swapChain = new SwapChain(device, frameBuilder, surface, renderPass, swapChain);
    }

    void drawNextFrame(void delegate(ref Frame frame) dg)
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

        dg(frame);

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
struct WorldTransformationUniformBuffer
{
    Matrix4f model; /// model to World
    Matrix4f view; /// World to view (to camera)
    Matrix4f proj; /// view to projection (to projective/homogeneous coordinates)
}
