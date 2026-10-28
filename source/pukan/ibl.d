module pukan.ibl;

import dlib.math: Vector2f, Vector3f, cross, dot;
import pukan.vulkan;
import pukan.vulkan.bindings;
import pukan.vulkan.textures: Texture;
import std.algorithm: max;
import std.math: PI, abs, acos, atan2, cos, floor, pow, sin, sqrt;

/// One CPU-side image level, RGBA8
struct ImageSpec
{
    uint width;
    uint height;
    ubyte[] rgba;

    ubyte[] allPixelsAtOnce() => rgba;
}

struct IblTextures
{
    Texture irradiance;
    Texture prefiltered;
    Texture brdfLut;
}

/// Uploads the generated tables, with their mip chains
IblTextures createIblTextures(LogicalDevice device)
{
    auto images = generateIbl();

    auto commandPool = device.createCommandPool();
    scope(exit) destroy(commandPool);
    auto commandBuffers = commandPool.allocateBuffers(2);
    scope(exit) commandPool.freeBuffers(commandBuffers);

    VkSamplerCreateInfo samplerInfo = {
        sType: VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        magFilter: VK_FILTER_LINEAR,
        minFilter: VK_FILTER_LINEAR,
        mipmapMode: VK_SAMPLER_MIPMAP_MODE_LINEAR,
        addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        anisotropyEnable: VK_FALSE,
        borderColor: VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        unnormalizedCoordinates: VK_FALSE,
        compareEnable: VK_FALSE,
        compareOp: VK_COMPARE_OP_ALWAYS,
        minLod: 0,
        maxLod: VK_LOD_CLAMP_NONE,
    };

    IblTextures result;

    result.irradiance = device.create!Texture(
        loadImageToMemory(device, commandPool, commandBuffers[0], images.irradiance, VK_FORMAT_R8G8B8A8_UNORM),
        samplerInfo,
    );

    result.brdfLut = device.create!Texture(
        loadImageToMemory(device, commandPool, commandBuffers[1], images.brdfLut, VK_FORMAT_R8G8B8A8_UNORM),
        samplerInfo,
    );

    ubyte[][] levels;
    foreach(level; images.prefiltered)
        levels ~= level.rgba;

    result.prefiltered = device.create!Texture(
        loadImageWithMips(
            device,
            commandPool,
            commandBuffers[0],
            images.prefiltered[0].width,
            images.prefiltered[0].height,
            levels,
            VK_FORMAT_R8G8B8A8_UNORM,
        ),
        samplerInfo,
    );

    return result;
}

struct IblImages
{
    ImageSpec irradiance;
    ImageSpec[] prefiltered;
    ImageSpec brdfLut;
}

/// Generates the tables the pbr shader samples instead of the analytic sky
IblImages generateIbl()
{
    const environment = skyEnvironment();

    IblImages result;
    result.irradiance = irradianceMap(environment);
    result.prefiltered = prefilteredEnvironment(environment);
    result.brdfLut = brdfLut();

    return result;
}

/// Equirectangular map of the sky the analytic version used
ImageSpec skyEnvironment(uint width = 128, uint height = 64)
{
    ImageSpec image;
    image.width = width;
    image.height = height;
    image.rgba.length = width * height * 4;

    foreach(y; 0 .. height)
        foreach(x; 0 .. width)
        {
            const direction = equirectDirection(
                (cast(float) x + 0.5f) / width,
                (cast(float) y + 0.5f) / height,
            );

            store(image, x, y, sky(direction));
        }

    return image;
}

/// Cosine weighted incoming radiance over pi
ImageSpec irradianceMap(const ImageSpec environment, uint width = 32, uint height = 16)
{
    ImageSpec image;
    image.width = width;
    image.height = height;
    image.rgba.length = width * height * 4;

    const float texelSolidAngle = 2.0f * PI / environment.width * (PI / environment.height);
    const Vector3f zero = Vector3f(0, 0, 0);

    foreach(y; 0 .. height)
        foreach(x; 0 .. width)
        {
            const normal = equirectDirection(
                (cast(float) x + 0.5f) / width,
                (cast(float) y + 0.5f) / height,
            );

            Vector3f sum = zero;

            foreach(ey; 0 .. environment.height)
            {
                const theta = (cast(float) ey + 0.5f) / environment.height * PI;
                const solidAngle = texelSolidAngle * sin(theta);

                foreach(ex; 0 .. environment.width)
                {
                    const direction = equirectDirection(
                        (cast(float) ex + 0.5f) / environment.width,
                        (cast(float) ey + 0.5f) / environment.height,
                    );

                    const cosine = max(dot(normal, direction), 0.0f);

                    if(cosine > 0)
                        sum += environmentColor(environment, ex, ey) * (cosine * solidAngle);
                }
            }

            store(image, x, y, sum * (1.0f / PI));
        }

    return image;
}

/// GGX prefiltered chain, one roughness per level
ImageSpec[] prefilteredEnvironment(
    const ImageSpec environment,
    uint baseWidth = 128,
    uint baseHeight = 64,
    uint levels = 6,
)
{
    enum sampleCount = 64;

    ImageSpec[] result;
    const Vector3f zero = Vector3f(0, 0, 0);

    foreach(level; 0 .. levels)
    {
        const width = max(1u, baseWidth >> level);
        const height = max(1u, baseHeight >> level);
        const roughness = levels > 1 ? cast(float) level / (levels - 1) : 0;

        ImageSpec image;
        image.width = width;
        image.height = height;
        image.rgba.length = width * height * 4;

        foreach(y; 0 .. height)
            foreach(x; 0 .. width)
            {
                const normal = equirectDirection(
                    (cast(float) x + 0.5f) / width,
                    (cast(float) y + 0.5f) / height,
                );

                Vector3f sum = zero;
                float weight = 0;

                foreach(sampleIndex; 0 .. sampleCount)
                {
                    const half = importanceSampleGGX(hammersley(sampleIndex, sampleCount), roughness, normal);
                    const light = half * (2.0f * dot(normal, half)) - normal;
                    const cosine = max(dot(normal, light), 0.0f);

                    if(cosine > 0)
                    {
                        sum += sample(environment, equirectUv(light)) * cosine;
                        weight += cosine;
                    }
                }

                store(image, x, y, weight > 0 ? sum * (1.0f / weight) : zero);
            }

        result ~= image;
    }

    return result;
}

/// Split sum lookup: x = NdotV, y = roughness, R = scale, G = bias
ImageSpec brdfLut(uint size = 128)
{
    enum sampleCount = 64;

    ImageSpec image;
    image.width = size;
    image.height = size;
    image.rgba.length = size * size * 4;

    const Vector3f normal = Vector3f(0, 0, 1);

    foreach(y; 0 .. size)
        foreach(x; 0 .. size)
        {
            const NdotV = (cast(float) x + 0.5f) / size;
            const roughness = (cast(float) y + 0.5f) / size;
            const view = Vector3f(sqrt(1.0f - NdotV * NdotV), 0, NdotV);

            float scale = 0;
            float bias = 0;

            foreach(sampleIndex; 0 .. sampleCount)
            {
                const half = importanceSampleGGX(hammersley(sampleIndex, sampleCount), roughness, normal);
                const light = half * (2.0f * dot(view, half)) - view;

                if(light.z <= 0)
                    continue;

                const NdotL = light.z;
                const NdotH = max(half.z, 0.0f);
                const VdotH = max(dot(view, half), 0.0f);
                const geometry = geometrySmith(NdotV, NdotL, roughness);
                const visibility = geometry * VdotH / (NdotH * NdotV);
                const fresnel = pow(1.0f - VdotH, 5.0f);

                scale += (1.0f - fresnel) * visibility;
                bias += fresnel * visibility;
            }

            const offset = (y * size + x) * 4;
            image.rgba[offset + 0] = toByte(scale / sampleCount);
            image.rgba[offset + 1] = toByte(bias / sampleCount);
            image.rgba[offset + 2] = 0;
            image.rgba[offset + 3] = 255;
        }

    return image;
}

private Vector3f sky(const Vector3f direction)
{
    const float horizon = clamp(direction.y * 0.5f + 0.5f, 0.0f, 1.0f);
    const Vector3f ground = Vector3f(0.04f, 0.035f, 0.03f);
    const Vector3f zenith = Vector3f(0.35f, 0.45f, 0.65f);

    return ground + (zenith - ground) * horizon;
}

private Vector3f equirectDirection(float u, float v)
{
    const float phi = (u - 0.5f) * 2.0f * PI;
    const float theta = v * PI;
    const float sinTheta = sin(theta);

    return Vector3f(sin(phi) * sinTheta, cos(theta), -cos(phi) * sinTheta);
}

private Vector2f equirectUv(const Vector3f direction)
{
    return Vector2f(
        atan2(direction.x, -direction.z) / (2.0f * PI) + 0.5f,
        acos(clamp(direction.y, -1.0f, 1.0f)) / PI,
    );
}

private Vector3f environmentColor(const ImageSpec image, uint x, uint y)
{
    const offset = (y * image.width + x) * 4;

    return Vector3f(
        image.rgba[offset + 0] / 255.0f,
        image.rgba[offset + 1] / 255.0f,
        image.rgba[offset + 2] / 255.0f,
    );
}

private Vector3f sample(const ImageSpec image, const Vector2f uv)
{
    const float x = uv.x * image.width - 0.5f;
    const float y = uv.y * (image.height - 1);

    const int x0 = cast(int) floor(x);
    const int y0 = cast(int) floor(y);
    const float fx = x - x0;
    const float fy = y - y0;

    Vector3f result = Vector3f(0, 0, 0);

    foreach(dy; 0 .. 2)
        foreach(dx; 0 .. 2)
        {
            const wrappedX = (x0 + dx) % cast(int) image.width;
            const column = cast(uint) (wrappedX < 0 ? wrappedX + image.width : wrappedX);
            const row = cast(uint) clamp(cast(float) (y0 + dy), 0.0f, image.height - 1.0f);
            const weight = (dx == 0 ? 1.0f - fx : fx) * (dy == 0 ? 1.0f - fy : fy);

            result += environmentColor(image, column, row) * weight;
        }

    return result;
}

private Vector2f hammersley(uint index, uint count)
{
    return Vector2f(cast(float) index / count, radicalInverse(index));
}

private float radicalInverse(uint bits)
{
    bits = (bits << 16) | (bits >> 16);
    bits = ((bits & 0x55555555u) << 1) | ((bits & 0xAAAAAAAAu) >> 1);
    bits = ((bits & 0x33333333u) << 2) | ((bits & 0xCCCCCCCCu) >> 2);
    bits = ((bits & 0x0F0F0F0Fu) << 4) | ((bits & 0xF0F0F0F0u) >> 4);
    bits = ((bits & 0x00FF00FFu) << 8) | ((bits & 0xFF00FF00u) >> 8);

    return cast(float) bits * 2.3283064365386963e-10f;
}

private Vector3f importanceSampleGGX(const Vector2f xi, float roughness, const Vector3f normal)
{
    const float alpha = roughness * roughness;
    const float phi = 2.0f * PI * xi.x;
    const float cosTheta = sqrt((1.0f - xi.y) / (1.0f + (alpha * alpha - 1.0f) * xi.y));
    const float sinTheta = sqrt(max(1.0f - cosTheta * cosTheta, 0.0f));

    const Vector3f local = Vector3f(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
    const Vector3f up = abs(normal.z) < 0.999f ? Vector3f(0, 0, 1) : Vector3f(1, 0, 0);
    const Vector3f tangent = cross(up, normal).normalized;
    const Vector3f bitangent = cross(normal, tangent);

    return tangent * local.x + bitangent * local.y + normal * local.z;
}

private float geometrySmith(float NdotV, float NdotL, float roughness)
{
    const float k = roughness * roughness / 2.0f;

    return NdotV / (NdotV * (1.0f - k) + k) * (NdotL / (NdotL * (1.0f - k) + k));
}

private float clamp(float value, float low, float high)
{
    return value < low ? low : value > high ? high : value;
}

private ubyte toByte(float value)
{
    const float scaled = clamp(value, 0.0f, 1.0f) * 255.0f + 0.5f;

    return cast(ubyte) scaled;
}

private void store(ref ImageSpec image, uint x, uint y, const Vector3f color)
{
    const offset = (y * image.width + x) * 4;
    image.rgba[offset + 0] = toByte(color.x);
    image.rgba[offset + 1] = toByte(color.y);
    image.rgba[offset + 2] = toByte(color.z);
    image.rgba[offset + 3] = 255;
}
