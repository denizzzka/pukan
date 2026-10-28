import pukan;
import pukan.vulkan.bindings;
import pukan.vulkan.requirements: Requirements;
import std.algorithm: max;
import std.exception: enforce;
import std.math: abs;
import std.meta: AliasSeq;
import std.random;
import std.stdio;

debug alias DebugEntities = LayerSettings;
else alias DebugEntities = AliasSeq!();

alias appRequirements = Requirements!(Gemm);

void main()
{
    version(linux)
    {
        import etc.linux.memoryerror;
        registerMemoryAssertHandler();
    }

    enum M = 128;
    enum N = 96;
    enum K = 64;

    auto randGen = Random(42);

    auto A = new float[M * K];
    auto B = new float[K * N];

    foreach(ref e; A)
        e = uniform(0.0f, 1.0f, randGen);

    foreach(ref e; B)
        e = uniform(0.0f, 1.0f, randGen);

    auto cpuC = new float[M * N];
    cpuC[] = 0;

    foreach(i; 0 .. M)
        foreach(k; 0 .. K)
            foreach(j; 0 .. N)
                cpuC[i * N + j] += A[i * K + k] * B[k * N + j];

    const(char*)[] extension_list;
    auto vk = Instance.createWith!DebugEntities("compute demo", 1, extension_list);
    scope(exit) destroy(vk);

    ImageFormatRequest sampled;
    sampled.format = VK_FORMAT_R8G8B8A8_UNORM;
    sampled.imageType = VK_IMAGE_TYPE_2D;
    sampled.tiling = VK_IMAGE_TILING_OPTIMAL;
    sampled.usage = VK_IMAGE_USAGE_SAMPLED_BIT;
    sampled.extent = VkExtent3D(640u, 480u, 1u);

    DeviceFilter filter;
    filter.images = [sampled];

    auto selected = vk.findSuitablePhysicalDevice!appRequirements(filter);
    auto physDevice = selected.device();

    auto device = selected.createLogicalDevice();
    scope(exit) destroy(device);

    string formatReason;
    enforce(device.supportsImageFormat(sampled, formatReason),
        "sampled image format is not supported: " ~ formatReason);

    sampled.extent = VkExtent3D(1u << 20, 1u, 1u);
    enforce(!device.supportsImageFormat(sampled, formatReason),
        "oversized image extent was accepted");

    auto gemm = Gemm.create(device, M, N, K);
    scope(exit) destroy(gemm);

    gemm.setA(A);
    gemm.setB(B);

    gemm.run();

    auto gpuC = gemm.downloadC();

    float maxErr = 0;
    foreach(i; 0 .. M * N)
        maxErr = max(maxErr, abs(gpuC[i] - cpuC[i]));

    writeln("M = ", M, " N = ", N, " K = ", K);
    writeln("max abs error GPU vs CPU = ", maxErr);

    enum maxAllowedError = 1e-4;

    enforce(maxErr < maxAllowedError, "GEMM error exceeds the limit");
    writeln("PASS");

    enum beta = 2.0f;
    enum alpha = 1.5f;

    auto oldC = new float[M * N];
    foreach(ref e; oldC)
        e = uniform(0.0f, 1.0f, randGen);

    gemm.setC(oldC);
    gemm.run(alpha, beta);

    gpuC = gemm.downloadC();

    float maxErrAB = 0;
    foreach(i; 0 .. M * N)
    {
        const expected = alpha * cpuC[i] + beta * oldC[i];
        maxErrAB = max(maxErrAB, abs(gpuC[i] - expected));
    }

    writeln("C = alpha*A*B + beta*C: max abs error = ", maxErrAB);

    enforce(maxErrAB < maxAllowedError, "GEMM error with alpha and beta exceeds the limit");
    writeln("PASS");

    stdout.flush();
}
