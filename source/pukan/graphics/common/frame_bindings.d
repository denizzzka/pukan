module pukan.graphics.common.frame_bindings;

import pukan.frame_bindings;
import pukan.vulkan.bindings;
import pukan.vulkan.frame_bindings: FrameBindings;

/// The frame descriptor set layout, in the binding order the shaders declare
enum frameSetBindings = [
    VkDescriptorSetLayoutBinding(
        binding: FRAME_UNIFORM,
        descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_IRRADIANCE,
        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_PREFILTERED,
        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_BRDF_LUT,
        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_SCENE_COLOR,
        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_OIT_HEADS,
        descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_OIT_FRAGMENTS,
        descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_OIT_COUNTER,
        descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_LIGHTS,
        descriptorType: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_SHADOW_MAP,
        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_SHADOW_MAP1,
        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_SHADOW_MAP2,
        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_SCENE_DEPTH,
        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
    VkDescriptorSetLayoutBinding(
        binding: FRAME_DEPTH_MS,
        descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        descriptorCount: 1,
        stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
    ),
];

/// The same set as indices, for the writes `FrameSet` does
enum frameBindings = FrameBindings(
    uniform: FRAME_UNIFORM,
    irradiance: FRAME_IRRADIANCE,
    prefiltered: FRAME_PREFILTERED,
    brdfLut: FRAME_BRDF_LUT,
    sceneColor: FRAME_SCENE_COLOR,
    oitHeads: FRAME_OIT_HEADS,
    oitFragments: FRAME_OIT_FRAGMENTS,
    oitCounter: FRAME_OIT_COUNTER,
    lights: FRAME_LIGHTS,
    shadowMap: FRAME_SHADOW_MAP,
    shadowMap1: FRAME_SHADOW_MAP1,
    shadowMap2: FRAME_SHADOW_MAP2,
    sceneDepth: FRAME_SCENE_DEPTH,
    depthMS: FRAME_DEPTH_MS,
);
