#version 460

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inUv;
layout(location = 2) in vec4 inColor;

layout(push_constant) uniform UiData
{
    vec4 transform; // xy = pixels to clip, zw = offset
};

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;

void main()
{
    gl_Position = vec4(inPosition * transform.xy + transform.zw, 0.0, 1.0);
    uv = inUv;
    color = inColor;
}
