module pukan.vulkan.shaders;

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
