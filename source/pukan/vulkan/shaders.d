module pukan.vulkan.shaders;

import dlib.math;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.exceptions;
import std.exception: enforce;

///
class ShaderModule
{
    LogicalDevice device;
    VkShaderModule shaderModule;

    //TODO: remove?
    this(LogicalDevice dev, string filename)
    {
        import std.file: read;

        auto code = cast(ubyte[]) read(filename);

        enforce!PukanException(code.length % 4 == 0, "SPIR-V code size must be a multiple of 4");

        this(dev, code);
    }

    this(LogicalDevice dev, ubyte[] sprivBinary)
    in(sprivBinary.length % 4 == 0)
    {
        device = dev;

        VkShaderModuleCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            codeSize: sprivBinary.length,
            pCode: cast(uint*) sprivBinary.ptr,
        };

        vkCreateShaderModule(dev.device, &cinf, dev.alloc, &shaderModule).vkCheck;
    }

    ~this()
    {
        if(device && shaderModule)
            vkDestroyShaderModule(device.device, shaderModule, device.alloc);
    }

    auto createShaderStageInfo(VkShaderStageFlagBits stage)
    {
        VkPipelineShaderStageCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage: stage,
            pName: "main", // shader entry point
        };

        __traits(getMember, cinf, "module") = shaderModule;

        return cinf;
    }
}

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

struct UniformBufferObject
{
    Matrix4f model; /// model to World
    Matrix4f view; /// World to view (to camera)
    Matrix4f proj; /// view to projection (to projective/homogeneous coordinates)
}

const Vertex[] vertices = [
    Vertex(Vector3f(-0.5, -0.5, 0), Vector3f(1.0f, 0.0f, 0.0f), Vector2f(1, 0)),
    Vertex(Vector3f(0.5, -0.5, 0), Vector3f(0.0f, 1.0f, 0.0f), Vector2f(0, 0)),
    Vertex(Vector3f(0.5, 0.5, 0), Vector3f(0.0f, 0.0f, 1.0f), Vector2f(0, 1)),
    Vertex(Vector3f(-0.5, 0.5, 0), Vector3f(1.0f, 1.0f, 1.0f), Vector2f(1, 1)),

    Vertex(Vector3f(-0.5, -0.35, -0.5), Vector3f(1.0f, 0.0f, 0.0f), Vector2f(1, 0)),
    Vertex(Vector3f(0.5, -0.15, -0.5), Vector3f(0.0f, 1.0f, 0.0f), Vector2f(0, 0)),
    Vertex(Vector3f(0.5, 0.15, -0.5), Vector3f(0.0f, 0.0f, 1.0f), Vector2f(0, 1)),
    Vertex(Vector3f(-0.5, 0.35, -0.5), Vector3f(1.0f, 1.0f, 1.0f), Vector2f(1, 1)),
];

const ushort[] indices = [
    0, 1, 2, 2, 3, 0,
    4, 5, 6, 6, 7, 4,
];
