import dlib.math: Matrix4x4f, Vector3f, lookAtMatrix, perspectiveMatrix;
import pukan;
import pukan.vulkan.bindings;
import pukan.vulkan.core: FlightRecorder, LayerSettings;
import glfw3.api;
import std.exception: enforce;
import std.getopt: defaultGetoptPrinter, getopt;
import std.meta: AliasSeq;
import std.stdio: writeln;
import std.string: toStringz;

alias appRequirements = Requirements!(SwapChain, GodotFactory, FrameBuilder);
debug alias DebugEntities = AliasSeq!(FlightRecorder, LayerSettings);
else alias DebugEntities = AliasSeq!();

alias appEntities = AliasSeq!(DebugEntities, WindowSurface);

const(char)*[] glfwExtraExtensions(Modules...)()
{
    import std.algorithm: canFind;
    import std.conv: to;

    uint count;
    const char** required = glfwGetRequiredInstanceExtensions(&count);
    if(required is null)
        return null;

    enum declared = extensionNames!(
        RequirementsFor!(Instance, Modules),
        OptionalRequirementsFor!(Instance, Modules),
    );

    const(char)*[] ret;
    foreach(name; required[0 .. count])
        if(!declared.canFind(name.to!string))
            ret ~= name;

    return ret;
}

enum width = 800;
enum height = 600;
enum cameraFov = 45.0f;
enum cameraNear = 0.01f;
enum cameraFar = 100.0f;

void main(string[] args)
{
    string scenePath = "demo/assets/godot_samples/generated/procedural.tscn";

    auto getoptResult = getopt(
        args,
        "scene", "Godot scene to load", &scenePath,
    );

    if(getoptResult.helpWanted)
    {
        defaultGetoptPrinter("pukan Godot scene demo", getoptResult.options);
        return;
    }

    enforce(glfwInit());
    scope(exit) glfwTerminate();

    enforce(glfwVulkanSupported());
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);

    auto window = glfwCreateWindow(width, height, "pukan Godot scene".toStringz, null, null);
    enforce(window, "Cannot create a window");
    scope(exit) glfwDestroyWindow(window);

    auto vk = Instance.createWith!appEntities("pukan Godot scene", 1, glfwExtraExtensions!appEntities());
    scope(exit) destroy(vk);

    VkSurfaceKHR surface;
    static import glfw3.internal;
    glfwCreateWindowSurface(
        vk.instance,
        window,
        cast(glfw3.internal.VkAllocationCallbacks*) vk.allocator,
        cast(ulong*) &surface,
    );

    bool surfaceCheck(ref DeviceContext ctx, out string reason)
    {
        import std.conv: to;

        enum queueFlags = QueueFlagsFor!appRequirements;

        foreach(i, family; ctx.queueFamilies)
        {
            if((family.queueFlags & queueFlags) != queueFlags)
                continue;

            VkBool32 supported;
            vkGetPhysicalDeviceSurfaceSupportKHR(ctx.device, cast(uint) i, surface, &supported).vkCheck;

            if(supported != VK_TRUE)
            {
                reason = "queue family " ~ i.to!string ~ " does not support presentation";
                return false;
            }

            const format = chooseSurfaceFormat(ctx.device, surface, reason);
            if(format.format == VK_FORMAT_UNDEFINED)
                return false;

            return surfaceUsable(ctx.device, surface, format, reason);
        }

        reason = "no queue family supports " ~ queueFlags.to!string;
        return false;
    }

    DeviceFilter filter;
    filter.checks ~= DeviceCheck("surface", &surfaceCheck);

    auto selected = vk.findSuitablePhysicalDevice!appRequirements(filter);
    auto physDevice = selected.device();

    string surfaceReason;
    const surfaceFormat = physDevice.chooseSurfaceFormat(surface, surfaceReason);
    enforce(surfaceFormat.format != VK_FORMAT_UNDEFINED, surfaceReason);

    auto device = selected.createLogicalDevice!(Texture)();
    scope(exit)
    {
        import core.memory: GC;
        GC.collect();
        destroy(device);
    }

    debug auto dbg = vk.attachFlightRecorder(device);
    debug scope(exit) destroy(dbg);

    void windowSizeChanged()
    {
        int w;
        int h;
        glfwGetFramebufferSize(window, &w, &h);

        while(w == 0 || h == 0)
        {
            glfwGetFramebufferSize(window, &w, &h);
            glfwWaitEvents();
        }
    }

    scope scene = new Scene(device, surface, &windowSizeChanged, surfaceFormat);
    scope(exit) destroy(scene);

    scene.shadowsEnabled = false;

    auto godotScene = scene.godotFactory.create(scenePath);
    writeln("loaded ", scenePath, ": meshes ", godotScene.meshCount,
        ", nodes skipped ", godotScene.skippedNodes,
        ", resources skipped ", godotScene.skippedResources);

    auto initialBuffer = &scene.swapChain.frames[0].commandBuffer();
    godotScene.uploadToGPUImmediate(device, scene.frameBuilder.commandPool, *initialBuffer);

    const eye = Vector3f(0, 2.5f, -3.0f);
    const target = Vector3f(0, 1.5f, 0);
    const up = Vector3f(0, 1, 0);

    while(!glfwWindowShouldClose(window))
    {
        glfwPollEvents();

        WorldTransformation wtb;
        wtb.model = Matrix4x4f.identity();
        wtb.view = lookAtMatrix(eye, target, up);
        wtb.proj = perspectiveMatrix(
            cameraFov,
            cast(float) scene.swapChain.imageExtent.width / scene.swapChain.imageExtent.height,
            cameraNear,
            cameraFar,
        );

        scene.drawNextFrame((ref FrameBuilder fb, ref Frame frame) {
            {
                DefaultRenderPass.VariableData renderData;
                renderData.common.imageExtent = scene.swapChain.imageExtent;
                renderData.common.frameBuffer = frame.frameBuffer;
                scene.renderPass.updateData(renderData);
            }

            scene.updateFrameUniforms(frame, 0, wtb);

            const modelViewProj = wtb.proj * wtb.view * wtb.model;


            scene.recordCommandBuffer(
                frame,
                (buf, phase) {
                    godotScene.drawingBufferFilling(buf, modelViewProj, frame.frameSets[0].descriptorSet, phase);
                },
                null,
                (buf) {
                    godotScene.drawingBufferFilling(buf, scene.shadowViewProj * wtb.model, frame.frameSets[0].descriptorSet, DrawPhase.shadow);
                },
            );
        });
    }

    vkDeviceWaitIdle(device.device);
}
