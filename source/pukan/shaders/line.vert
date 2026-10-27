#version 460

layout(push_constant) uniform Push
{
    mat4 mvp;
    vec2 viewport;
} pc;

layout(location = 0) in vec2 corner;
layout(location = 1) in vec4 p0w;
layout(location = 2) in vec4 p1w;
layout(location = 3) in vec4 color;

layout(location = 0) out vec4 fragColor;

void main()
{
    const vec4 c0 = pc.mvp * vec4(p0w.xyz, 1.0);
    const vec4 c1 = pc.mvp * vec4(p1w.xyz, 1.0);

    const vec2 s0 = c0.xy / c0.w;
    const vec2 s1 = c1.xy / c1.w;
    const vec2 d = (s1 - s0) * pc.viewport;

    const float len = length(d);
    const vec2 dir = len > 1e-6 ? d / len : vec2(1.0, 0.0);
    const vec2 normal = vec2(-dir.y, dir.x);

    const vec4 base = corner.x < 0.5 ? c0 : c1;
    const vec2 offset = normal * (p0w.w / pc.viewport) * corner.y;

    vec4 clip = base;
    clip.xy += offset * base.w;
    gl_Position = clip;

    fragColor = color;
}
