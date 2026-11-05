#version 460

layout(binding = 0) uniform sampler2D fontAtlas;

layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 color;

layout(location = 0) out vec4 outColor;

vec3 srgbToLinear(vec3 color)
{
    const vec3 low = color / 12.92;
    const vec3 high = pow((color + 0.055) / 1.055, vec3(2.4));

    return mix(low, high, step(vec3(0.04045), color));
}

void main()
{
    const vec4 sampled = color * texture(fontAtlas, uv);

    // The target is an sRGB image, so blending happens in linear space
    outColor = vec4(srgbToLinear(sampled.rgb), sampled.a);
}
