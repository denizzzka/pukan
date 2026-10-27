module pukan.vulkan.defaults;

import pukan.vulkan.bindings;

// Non-programmable stages:

VkPipelineMultisampleStateCreateInfo multisampling = {
    sType: VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    sampleShadingEnable: VK_FALSE,
    rasterizationSamples: VK_SAMPLE_COUNT_1_BIT,
    minSampleShading: 1.0f, // Optional
    pSampleMask: null, // Optional
    alphaToCoverageEnable: VK_FALSE, // Optional
    alphaToOneEnable: VK_FALSE, // Optional
};


