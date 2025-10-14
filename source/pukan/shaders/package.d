module pukan.shaders;

import pukan.vulkan.bindings;
import pukan.vulkan.logical_device;
import pukan.vulkan.shaders;

ShaderInfo vertShader;
ShaderInfo coloredFragShader;
ShaderInfo texturedFragShader;

ShaderInfo gltf_vertShader;
ShaderInfo gltf_fragShader;

void initShaders(size_t boneMatrixSize)(LogicalDevice device)
{
    vertShader = device.uploadShaderToGPU(
        cast(ubyte[]) import("vert.spv"),
        VK_SHADER_STAGE_VERTEX_BIT,
        null,
        VkPushConstantRange(
            stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
            offset: 0,
            size: boneMatrixSize,
        )
    );

    coloredFragShader = device.uploadShaderToGPU(
        cast(ubyte[]) import("colored_frag.spv"),
        VK_SHADER_STAGE_FRAGMENT_BIT,
        null
    );

    texturedFragShader = device.uploadShaderToGPU(
        cast(ubyte[]) import("textured_frag.spv"),
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

    gltf_vertShader = device.uploadShaderToGPU(
        cast(ubyte[]) import("gltf_vertices.spv"),
        VK_SHADER_STAGE_VERTEX_BIT,
        null,
        VkPushConstantRange(
            stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
            offset: 0,
            size: boneMatrixSize,
        )
    );

    gltf_fragShader = device.uploadShaderToGPU(
        cast(ubyte[]) import("gltf_fragment.spv"),
        VK_SHADER_STAGE_FRAGMENT_BIT,
        [
            VkDescriptorSetLayoutBinding(
                binding: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
            ),
        ],
    );
}
