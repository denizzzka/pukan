module pukan.vulkan.shaders;

import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.exceptions;
import std.exception: enforce;

///
class LoadedShaderModule
{
    LogicalDevice device;
    VkShaderModule shaderModule;
    VkShaderStageFlagBits stage;

    //TODO: remove?
    this(LogicalDevice dev, VkShaderStageFlagBits stage, string filename)
    {
        import std.file: read;

        auto code = cast(ubyte[]) read(filename);

        enforce!PukanException(code.length % 4 == 0, "SPIR-V code size must be a multiple of 4");

        this(dev, stage, code);
    }

    this(LogicalDevice dev, VkShaderStageFlagBits stage, ubyte[] sprivBinary)
    in(sprivBinary.length % 4 == 0)
    {
        device = dev;

        VkShaderModuleCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            codeSize: sprivBinary.length,
            pCode: cast(uint*) sprivBinary.ptr,
        };

        vkCreateShaderModule(dev.device, &cinf, dev.alloc, &shaderModule).vkCheck;

        this.stage = stage;
    }

    ~this()
    {
        if(device && shaderModule)
            vkDestroyShaderModule(device.device, shaderModule, device.alloc);
    }

    auto createShaderStageInfo()
    {
        VkPipelineShaderStageCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            stage: stage,
            pName: "main", // shader entry point
        };

        // "module" is D keyword, workaround:
        __traits(getMember, cinf, "module") = shaderModule;

        return cinf;
    }
}
