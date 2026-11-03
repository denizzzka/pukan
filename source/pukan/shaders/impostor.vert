#version 460

// A camera-facing card that shows the colour a cell was captured into

layout(push_constant) uniform Push
{
    mat4 mvp;
} pc;

layout(location = 0) out vec2 uv;

void main()
{
    // Four corners of a triangle strip; the image's top row is its v = 0
    const vec2 corner = vec2((gl_VertexIndex & 1) * 2.0 - 1.0, (gl_VertexIndex >> 1) * 2.0 - 1.0);

    uv = vec2(corner.x * 0.5 + 0.5, 0.5 - corner.y * 0.5);
    gl_Position = pc.mvp * vec4(corner, 0.0, 1.0);
}
