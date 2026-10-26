#version 460

layout(push_constant) uniform Push {
    mat4 mvp;
} pc;

layout(set = 0, binding = 0) uniform Palette {
    vec4 colors[16];
} palette;

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;

layout(location = 2) in vec4 instanceP0;
layout(location = 3) in vec4 instanceAxis;
layout(location = 4) in vec4 instanceU;
layout(location = 5) in vec4 instanceV;

layout(location = 0) out vec3 normalOut;
layout(location = 1) flat out vec3 instanceColor;

void main()
{
    const vec3 world =
        instanceP0.xyz +
        instanceAxis.xyz * position.y +
        instanceU.xyz * position.x +
        instanceV.xyz * position.z;

    gl_Position = pc.mvp * vec4(world, 1.0);

    const vec3 n =
        instanceAxis.xyz * normal.y +
        instanceU.xyz * normal.x +
        instanceV.xyz * normal.z;

    normalOut = normalize(n);
    instanceColor = palette.colors[uint(instanceP0.w)].rgb;
}
