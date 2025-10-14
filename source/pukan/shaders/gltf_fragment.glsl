#version 460

//~ struct Material {
    //~ vec4 baseColorFactor;
//~ };

//TODO: include UniformBufferObject from vertices shader
//~ layout(binding = 0) uniform UniformBufferObject {
    //~ Material material;
//~ } ubo;

//~ layout(location = 8) in vec4 fragColor;
layout(location = 0) out vec4 outColor;

void main() {
    outColor = vec4(0, 1, 0, 0);
    //~ outColor = fragColor;
    //~ outColor = ubo.material.baseColorFactor;
}
