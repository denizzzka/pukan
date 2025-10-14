#version 460

struct Material {
    vec4 baseColorFactor;
};

//~ layout(binding = 0) uniform UniformBufferObject {
    //~ Material material;
//~ } ubo;

layout(push_constant) uniform PushConsts {
    mat4 transl;
} pushConsts;

layout(location = 0) in vec3 position;

//~ layout(location = 8) out vec4 fragColor;

void main() {
    gl_Position = pushConsts.transl * vec4(position, 1.0);
    //~ fragColor = ubo.material.baseColorFactor;
}
