module pukan.vulkan.shaders;

package mixin template Shaders()
{
    import std.container.slist;
    private SList!ShaderInfo loadedShaders;

    ref ShaderInfo uploadShaderToGPU(VkShaderStageFlagBits stage, ubyte[] sprivBinary)
    in(sprivBinary.length % 4 == 0)
    {
        loadedShaders.insert = ShaderInfo();

        VkShaderModuleCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            codeSize: sprivBinary.length,
            pCode: cast(uint*) sprivBinary.ptr,
        };

        vkCreateShaderModule(device, &cinf, this.alloc, &loadedShaders.front.shaderModule).vkCheck;
        loadedShaders.front.stage = stage;

        return loadedShaders.front;
    }

    //TODO: remove?
    auto uploadShaderFromFileToGPU(VkShaderStageFlagBits stage, string filename)
    {
        import std.file: read;

        auto code = cast(ubyte[]) read(filename);

        enforce!PukanException(code.length % 4 == 0, "SPIR-V code size must be a multiple of 4");

        return uploadShaderToGPU(stage, code);
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
