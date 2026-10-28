struct FrameData
{
    mat4 invViewProj;
    vec4 cameraPosition;
    vec4 lightDirection;
    vec4 lightColor;
    vec4 exposureParams; // x = exposure, y = IBL intensity
};

layout(set = 1, binding = 0) uniform FrameBlock
{
    FrameData frame;
} frameUbo;
