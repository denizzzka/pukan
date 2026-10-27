#version 460

#include "frame.glsl"

layout(push_constant) uniform Push {
    mat4 mvp;
} pc;

layout(location = 0) in vec3 position;
layout(location = 1) in vec3 normal;

layout(location = 2) in vec4 instanceP0;
layout(location = 3) in vec4 instanceAxis;
layout(location = 4) in vec4 instanceU;
layout(location = 5) in vec4 instanceV;

layout(location = 0) out vec3 normalOut;
layout(location = 1) flat out uint materialIndex;
layout(location = 2) out vec3 worldPosition;

void main()
{
    const vec3 world =
        instanceP0.xyz +
        instanceAxis.xyz * position.y +
        instanceU.xyz * position.x +
        instanceV.xyz * position.z;

    const mat4 model = frameUbo.frame.invViewProj * pc.mvp;
    const mat3 normalMatrix = transpose(inverse(mat3(model)));

    gl_Position = pc.mvp * vec4(world, 1.0);

    const vec3 n =
        instanceAxis.xyz * normal.y +
        instanceU.xyz * normal.x +
        instanceV.xyz * normal.z;

    normalOut = normalize(normalMatrix * n);
    materialIndex = uint(instanceP0.w);
    worldPosition = (model * vec4(world, 1.0)).xyz;
}
