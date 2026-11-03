module pukan.graphics.common.shaders;

import pukan.vulkan.bindings;
import pukan.vulkan.shaders: ShaderDecl, ShaderVertexInput;

/**
    Declares a pipeline stage from SPIR-V embedded at build time.

    The checksum is embedded too and identifies the binary in the pipeline
    cache.
*/
ShaderDecl shaderStage(string name)(
    VkShaderStageFlagBits stage,
    VkDescriptorSetLayoutBinding[] layoutBindings,
    VkPushConstantRange pushConstant = VkPushConstantRange.init,
    ShaderVertexInput vertexInput = ShaderVertexInput.init,
)
{
    const sum = cast(const ubyte[]) import(name ~ ".sum");
    static assert(import(name ~ ".sum").length == 16,
        "shader checksum must be 16 bytes: " ~ name);

    ubyte[16] checksum;
    checksum[] = sum;

    return ShaderDecl(
        file: name,
        stage: stage,
        layoutBindings: layoutBindings,
        pushConstantRange: pushConstant,
        vertexInput: vertexInput,
        binary: cast(const ubyte[]) import(name),
        checksum: checksum,
    );
}
