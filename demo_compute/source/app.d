import pukan;
import pukan.vulkan.bindings;
import std.algorithm: max;
import std.math: abs;
import std.random;
import std.stdio;

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
    auto vk = new Instance("compute demo", makeApiVersion(0, 1, 3, 0), extension_list);
    scope(exit) destroy(vk);

    auto physDevice = vk.findSuitablePhysicalDevice;

    const(char*)[] dev_extension_list;
    auto device = physDevice.createLogicalDevice(dev_extension_list);
    scope(exit) destroy(device);

    auto gemm = new Gemm(device, M, N, K);
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

    if(maxErr < maxAllowedError)
        writeln("PASS");
    else
        writeln("FAIL");

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

    if(maxErrAB < maxAllowedError)
        writeln("PASS");
    else
        writeln("FAIL");

    stdout.flush();
}
