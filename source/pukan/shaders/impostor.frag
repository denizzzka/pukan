#version 460

// Draws the captured colour of a cell, dropping the pixels it left clear

layout(binding = 0) uniform sampler2D impostorTexture;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 outColor;

void main()
{
    const vec4 texel = texture(impostorTexture, uv);

    if(texel.a < 0.5)
        discard;

    outColor = vec4(texel.rgb, 1.0);
}
