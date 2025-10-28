module pukan.vulkan.defaults;

import pukan.vulkan.bindings;

// Non-programmable stages:

VkPipelineInputAssemblyStateCreateInfo inputAssembly = {
    sType: VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
    topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    primitiveRestartEnable: VK_FALSE,
};

VkPipelineMultisampleStateCreateInfo multisampling = {
    sType: VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
    sampleShadingEnable: VK_FALSE,
    rasterizationSamples: VK_SAMPLE_COUNT_1_BIT,
    minSampleShading: 1.0f, // Optional
    pSampleMask: null, // Optional
    alphaToCoverageEnable: VK_FALSE, // Optional
    alphaToOneEnable: VK_FALSE, // Optional
};

shared VkPipelineColorBlendAttachmentState colorBlendAttachment = {
    colorWriteMask: VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
    blendEnable: VK_FALSE,
    srcColorBlendFactor: VK_BLEND_FACTOR_ONE, // Optional
    dstColorBlendFactor: VK_BLEND_FACTOR_ZERO, // Optional
    colorBlendOp: VK_BLEND_OP_ADD, // Optional
    srcAlphaBlendFactor: VK_BLEND_FACTOR_ONE, // Optional
    dstAlphaBlendFactor: VK_BLEND_FACTOR_ZERO, // Optional
    alphaBlendOp: VK_BLEND_OP_ADD, // Optional
};

VkPipelineColorBlendStateCreateInfo colorBlending = {
    sType: VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
    logicOpEnable: VK_FALSE,
    logicOp: VK_LOGIC_OP_COPY, // Optional
    attachmentCount: 1,
    pAttachments: &cast(VkPipelineColorBlendAttachmentState) colorBlendAttachment,
    blendConstants: [0.0f, 0.0f, 0.0f, 0.0f], // Optional
};
