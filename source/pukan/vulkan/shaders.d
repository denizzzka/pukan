module pukan.vulkan.shaders;

package mixin template Shaders()
{
    /*FIXME private*/ ShaderInfo[] loadedShaders;

    void uploadShaderToGPU(VkShaderStageFlagBits stage, ubyte[] sprivBinary)
    in(sprivBinary.length % 4 == 0)
    {
        loadedShaders.length++;
        auto added = &loadedShaders[$-1];

        VkShaderModuleCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            codeSize: sprivBinary.length,
            pCode: cast(uint*) sprivBinary.ptr,
        };

        vkCreateShaderModule(device, &cinf, this.alloc, &added.shaderModule).vkCheck;
        added.stage = stage;
    }

    //TODO: remove?
    void uploadShaderFromFileToGPU(VkShaderStageFlagBits stage, string filename)
    {
        import std.file: read;

        auto code = cast(ubyte[]) read(filename);

        enforce!PukanException(code.length % 4 == 0, "SPIR-V code size must be a multiple of 4");

        uploadShaderToGPU(stage, code);
    }

    private void shadersDtor()
    {
        foreach(e; loadedShaders)
            vkDestroyShaderModule(device, e.shaderModule, alloc);
    }
}

import pukan.vulkan.bindings;

struct ShaderInfo
{
    VkShaderModule shaderModule;
    VkShaderStageFlagBits stage;

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
