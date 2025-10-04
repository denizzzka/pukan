module pukan.vulkan.shaders;

import dlib.math;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.exceptions;
import std.file: read;
import std.exception: enforce;

class ShaderModule
{
    LogicalDevice device;
    VkShaderModule shaderModule;

    this(LogicalDevice dev, string filename)
    {
        auto code = cast(ubyte[]) read(filename);

        enforce!PukanException(code.length % 4 == 0, "SPIR-V code size must be a multiple of 4");

        this(dev, code);
    }

    this(LogicalDevice dev, ubyte[] sprivCode)
    in(sprivCode.length % 4 == 0)
    {
        device = dev;
        const code = cast(uint[]) sprivCode;

        VkShaderModuleCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            codeSize: sprivCode.length,
            pCode: code.ptr,
        };

        vkCreateShaderModule(dev.device, &cinf, dev.backend.allocator, &shaderModule).vkCheck;
    }

    ~this()
    {
        if(device && shaderModule)
            vkDestroyShaderModule(device.device, shaderModule, device.backend.allocator);
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

class CompilableShaderModule
{
    LogicalDevice device;
    VkShaderModule shaderModule;
    VkShaderEXT ext; /// Used by VK_EXT_shader_object
    private void[] data;

    this(LogicalDevice dev, string filename)
    {
        device = dev;

        data = read(filename);

        enforce!PukanException(data.length % 4 == 0, "SPIR-V code size must be a multiple of 4");

        const code = cast(uint[]) data;

        VkShaderModuleCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            codeSize: data.length,
            pCode: code.ptr,
        };

        vkCreateShaderModule(dev.device, &cinf, dev.backend.allocator, &shaderModule).vkCheck;
    }

    /// VK_EXT_shader_object extension
    void compileShader(VkShaderStageFlagBits stage)
    {
        auto vkCreateShadersEXT = cast(PFN_vkCreateShadersEXT) vkGetInstanceProcAddr(device.backend.instance, "vkCreateShadersEXT");

        const code = cast(uint[]) data;

        VkShaderCreateInfoEXT createInfoEXT = {
            sType: VK_STRUCTURE_TYPE_SHADER_CREATE_INFO_EXT,
            codeType: VK_SHADER_CODE_TYPE_SPIRV_EXT,
            codeSize: data.length,
            pCode: code.ptr,
            pName: "main",
            stage: stage,
        };

        vkCreateShadersEXT(device, 1, &createInfoEXT, device.backend.allocator, &ext).vkCheck;
    }

    ~this()
    {
        assert(device.device);

        if(ext)
        {
            auto vkDestroyShaderEXT = cast(PFN_vkDestroyShaderEXT) vkGetInstanceProcAddr(device.backend.instance, "vkDestroyShaderEXT");
            vkDestroyShaderEXT(device, ext, device.backend.allocator);
        }

        if(shaderModule)
            vkDestroyShaderModule(device.device, shaderModule, device.backend.allocator);
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
