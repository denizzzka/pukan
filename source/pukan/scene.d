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

    VkQueue graphicsQueue;
    VkQueue presentQueue;

    static struct Doubled
    {
        PoolAndLayoutInfo poolAndLayout;
        VkDescriptorSet[] descriptorsSet;
        DefaultGraphicsPipelineInfoCreator!Vertex pipelineInfoCreator;
        VkGraphicsPipelineCreateInfo pipelineCreateInfo;
        VkPipeline graphicsPipeline;
    }

    Doubled[2] dbl;

    this(LogicalDevice dev, VkSurfaceKHR surf, WindowSizeChangeDetectedCallback wsc)
    {
        device = dev;
        surface = surf;
        windowSizeChanged = wsc;

        device.physicalDevice.instance.useSurface(surface);

        renderPass = device.create!DefaultRenderPass(VK_FORMAT_B8G8R8A8_SRGB);

        frameBuilder = device.create!FrameBuilder(WorldTransformationUniformBuffer.sizeof);
        swapChain = new SwapChain(device, frameBuilder, surface, renderPass, null);

        auto vertShader = device.uploadShaderFromFileToGPU(
            "vert.spv",
            VK_SHADER_STAGE_VERTEX_BIT,
            [
                VkDescriptorSetLayoutBinding(
                    binding: 0,
                    descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                    descriptorCount: 1,
                    stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                ),
            ],
            VkPushConstantRange(
                stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
                offset: 0,
                size: Bone.mat.sizeof,
            )
        );

        auto coloredFragShader = device.uploadShaderFromFileToGPU("colored_frag.spv", VK_SHADER_STAGE_FRAGMENT_BIT, null);
        auto texturedFragShader = device.uploadShaderFromFileToGPU(
            "textured_frag.spv",
            VK_SHADER_STAGE_FRAGMENT_BIT,
            [
                VkDescriptorSetLayoutBinding(
                    binding: 1,
                    descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                    descriptorCount: 1,
                    stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
                ),
            ]
        );

        auto coloredShaderStages = [
            vertShader,
            coloredFragShader,
        ];

        auto texturedShaderStages = [
            vertShader,
            texturedFragShader,
        ];

        void initPoolAndPipelineInfo(S)(size_t i, S shaderStages)
        {
            auto layoutBindings = createLayoutBinding(shaderStages);
            dbl[i].poolAndLayout = device.createDescriptorPool(layoutBindings);
            dbl[i].descriptorsSet = device.allocateDescriptorSets(dbl[i].poolAndLayout, 1);
            dbl[i].pipelineInfoCreator = new DefaultGraphicsPipelineInfoCreator!Vertex(device, dbl[i].poolAndLayout.descriptorSetLayout, shaderStages, renderPass);
            dbl[i].pipelineCreateInfo = dbl[i].pipelineInfoCreator.pipelineCreateInfo;
            dbl[i].graphicsPipeline = device.createGraphicsPipelines([dbl[i].pipelineCreateInfo])[0];
        }

        initPoolAndPipelineInfo(0, coloredShaderStages);
        initPoolAndPipelineInfo(1, texturedShaderStages);
    }

    ~this()
    {
        // swapChain.frames should be destroyed before frameBuider
        swapChain.destroy;
        frameBuilder.destroy;
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
struct WorldTransformationUniformBuffer
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

    static auto getBindingDescription() {
        VkVertexInputBindingDescription r = {
            binding: 0,
            stride: this.sizeof,
            inputRate: VK_VERTEX_INPUT_RATE_VERTEX,
        };

        return r;
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
