module pukan.vulkan.shaders;

package mixin template Shaders()
{
    import std.container.slist;
    private SList!ShaderInfo loadedShaders;

    ref ShaderInfo uploadShaderToGPU(VkShaderStageFlagBits stage, VkDescriptorSetLayoutBinding[] layoutBindings, ubyte[] sprivBinary)
    in(sprivBinary.length % 4 == 0)
    {
        VkShaderModuleCreateInfo cinf = {
            sType: VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            codeSize: sprivBinary.length,
            pCode: cast(uint*) sprivBinary.ptr,
        };

        ShaderInfo added;
        vkCreateShaderModule(device, &cinf, this.alloc, &added.shaderModule).vkCheck;
        added.stage = stage;
        added.layoutBindings = layoutBindings;

        loadedShaders.insert(added);

        return loadedShaders.front;
    }

    //TODO: remove?
    auto uploadShaderFromFileToGPU(string filename, VkShaderStageFlagBits stage, VkDescriptorSetLayoutBinding[] layoutBindings)
    {
        import std.file: read;

        auto code = cast(ubyte[]) read(filename);

        enforce!PukanException(code.length % 4 == 0, "SPIR-V code size must be a multiple of 4");

        return uploadShaderToGPU(stage, layoutBindings, code);
    }

    private void shadersDtor()
    {
        foreach(e; loadedShaders)
            vkDestroyShaderModule(this.device, e.shaderModule, this.alloc);
    }
}

import pukan.vulkan.bindings;

struct ShaderInfo
{
    VkShaderModule shaderModule;
    VkShaderStageFlagBits stage;
    VkDescriptorSetLayoutBinding[] layoutBindings;

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

VkDescriptorSetLayoutBinding[] createLayoutBinding(ShaderInfo[] shaders)
{
    VkDescriptorSetLayoutBinding[] ret;

    foreach(ref shader; shaders)
    {
        foreach(ref b; shader.layoutBindings)
            assert(b.stageFlags == shader.stage);

        ret ~= shader.layoutBindings;
    }

    return ret;
}
