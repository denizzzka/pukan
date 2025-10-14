#version 460

layout(push_constant) uniform PushConsts {
    mat4 transl;
} pushConsts;

layout(location = 0) in vec3 position;

void main() {
    gl_Position = pushConsts.transl * vec4(position, 1.0);
}
