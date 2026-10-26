#version 460

layout(location = 0) in vec3 normal;
layout(location = 1) flat in vec3 instanceColor;

layout(location = 0) out vec4 outColor;

void main()
{
    const vec3 normalColor = normalize(normal) * 0.5 + 0.5;
    outColor = vec4(mix(normalColor, instanceColor, 0.2), 1.0);
}
