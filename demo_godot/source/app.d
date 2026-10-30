import dlib.math: Matrix4x4f, Vector3f;
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

Vector3f parseVector(string text)
{
    import std.algorithm: splitter;
    import std.conv: to;

    float[3] values;
    size_t count;

    foreach(part; text.splitter(','))
    {
        if(count == values.length)
            break;

        values[count++] = part.to!float;
    }

    return Vector3f(values[0], values[1], values[2]);
}

/// Names the content the loader saw but does not render
void printSkippedTypes(string label, size_t[string] counts)
{
    import std.algorithm: sort;
    import std.array: join;
    import std.format: format;

    if(counts.length == 0)
        return;

    string[] parts;
    foreach(type, count; counts)
        parts ~= format("%s x%d", type, count);

    parts.sort;
    writeln(label, ": ", parts.join(", "));
}

enum width = 800;
enum height = 600;
enum cameraFov = 45.0f;
enum cameraNear = 0.01f;
enum cameraFar = 100.0f;
enum cameraSpeed = 8.0f;
enum rollSpeed = 1.5f;

/// Input gathered by the GLFW callbacks, applied once per frame
private struct CameraInput
{
    double cursorX;
    double cursorY;
    bool cursorKnown;
    float lookX = 0;
    float lookY = 0;
    float zoom = 0;
    bool resetHeld;
}

private CameraInput cameraInput;

extern(C) void onCursorPos(GLFWwindow* window, double x, double y) nothrow @nogc
{
    if(cameraInput.cursorKnown && glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS)
    {
        cameraInput.lookX += cast(float) (x - cameraInput.cursorX);
        cameraInput.lookY += cast(float) (y - cameraInput.cursorY);
    }

    cameraInput.cursorX = x;
    cameraInput.cursorY = y;
    cameraInput.cursorKnown = true;
}

extern(C) void onScroll(GLFWwindow*, double, double yoffset) nothrow @nogc
{
    cameraInput.zoom += cast(float) yoffset;
}

void updateCamera(ref FlyCamera camera, GLFWwindow* window, float dt)
{
    float pressure(int key) nothrow @nogc
    {
        return glfwGetKey(window, key) == GLFW_PRESS ? 1.0f : 0.0f;
    }

    const local = Vector3f(
        pressure(GLFW_KEY_D) - pressure(GLFW_KEY_A),
        0,
        pressure(GLFW_KEY_W) - pressure(GLFW_KEY_S),
    );

    auto speed = camera.speed;
    if(pressure(GLFW_KEY_LEFT_SHIFT) + pressure(GLFW_KEY_RIGHT_SHIFT) > 0)
        speed *= 4;
    if(pressure(GLFW_KEY_LEFT_ALT) + pressure(GLFW_KEY_RIGHT_ALT) > 0)
        speed *= 0.25f;

    if(dt > 0)
    {
        camera.move(local, speed * dt);
        camera.rollBy((pressure(GLFW_KEY_Q) - pressure(GLFW_KEY_E)) * rollSpeed * dt);
    }

    const reset = pressure(GLFW_KEY_R) > 0;
    if(reset && !cameraInput.resetHeld)
        camera.resetRoll();
    cameraInput.resetHeld = reset;

    if(cameraInput.lookX != 0 || cameraInput.lookY != 0)
    {
        camera.look(cameraInput.lookX, cameraInput.lookY);
        cameraInput.lookX = 0;
        cameraInput.lookY = 0;
    }

    if(cameraInput.zoom != 0)
    {
        camera.zoom(cameraInput.zoom);
        cameraInput.zoom = 0;
    }
}

void main(string[] args)
{
    string scenePath;
    string packPath;
    bool useSceneCamera;
    uint frames;
    string screenshotPath;
    uint screenshotFrame;
    string eyeOption;
    string targetOption;
    bool noShadows;
    float fovOption = cameraFov;
    float farOption = cameraFar;
    float speedOption = cameraSpeed;

    auto getoptResult = getopt(
        args,
        "scene", "Godot scene to load; defaults to the pack main scene or a fixture", &scenePath,
        "pack", "load the scene from this PCK instead", &packPath,
        "scene-camera", "use the Camera3D from the scene", &useSceneCamera,
        "frames", "exit after N frames (0 = run forever)", &frames,
        "screenshot", "save the captured frame to this PNG", &screenshotPath,
        "screenshot-frame", "frame to capture (default: the last frame)", &screenshotFrame,
        "eye", "override the camera position, x,y,z", &eyeOption,
        "target", "override the camera target, x,y,z", &targetOption,
        "no-shadows", "do not cast shadows", &noShadows,
        "fov", "vertical field of view in degrees", &fovOption,
        "far", "far clipping distance", &farOption,
        "speed", "camera movement speed in units per second", &speedOption,
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

    glfwSetCursorPosCallback(window, &onCursorPos);
    glfwSetScrollCallback(window, &onScroll);

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

    scene.shadowsEnabled = !noShadows;

    if(scenePath.length == 0 && packPath.length == 0)
        scenePath = "demo_godot/godot_samples/generated/procedural.tscn";

    auto godotScene = packPath.length
        ? scene.godotFactory.createPacked(packPath, scenePath)
        : scene.godotFactory.create(scenePath);
    scope(exit) destroy(godotScene);
    writeln("loaded ", packPath.length ? packPath : scenePath, ": meshes ", godotScene.meshCount,
        ", geometries ", godotScene.geometryCount,
        ", nodes skipped ", godotScene.skippedNodes,
        ", resources skipped ", godotScene.skippedResources,
        ", lights ", godotScene.lights.length,
        ", instances ", godotScene.instanceCount,
        ", gltf assets ", scene.gltfFactory.cachedAssetCount);

    printSkippedTypes("nodes not rendered", godotScene.skippedNodeTypes);
    printSkippedTypes("resources not rendered", godotScene.skippedResourceTypes);

    foreach(bounds; godotScene.instanceBounds)
        writeln("instance aabb ", bounds.min.x, " ", bounds.min.y, " ", bounds.min.z,
            " ", bounds.max.x, " ", bounds.max.y, " ", bounds.max.z);

    foreach(light; godotScene.lights)
    {
        final switch(light.kind)
        {
            case GodotLightKind.directional:
                scene.setSun(light.direction, light.color, light.energy);
                break;

            case GodotLightKind.point:
                if(scene.activeLightCount >= maxLights)
                    break;
                scene.addPointLight(light.position, light.color * light.energy * 8.0f, light.range);
                break;

            case GodotLightKind.spot:
                if(scene.activeLightCount >= maxLights)
                    break;
                scene.addSpotLight(
                    light.position,
                    light.direction,
                    light.color * light.energy * 8.0f,
                    light.range,
                    light.innerAngle,
                    light.outerAngle,
                );
                break;
        }
    }

    auto initialBuffer = &scene.swapChain.frames[0].commandBuffer();
    godotScene.uploadToGPUImmediate(device, scene.frameBuilder.commandPool, *initialBuffer);

    Vector3f eye = Vector3f(0, 3.0f, -8.0f);
    Vector3f target = Vector3f(0, 1.5f, 0);

    if(eyeOption.length)
        eye = parseVector(eyeOption);
    if(targetOption.length)
        target = parseVector(targetOption);

    FlyCamera camera;
    float nearPlane = cameraNear;
    float farPlane = farOption;

    if(useSceneCamera && godotScene.hasCamera)
    {
        camera = FlyCamera.fromView(godotScene.camera.view);
        camera.fov = godotScene.camera.fov;
        nearPlane = godotScene.camera.nearPlane;
        farPlane = godotScene.camera.farPlane;
    }
    else
    {
        camera = FlyCamera.lookingAt(eye, target);
        camera.fov = fovOption;
    }

    camera.speed = speedOption;

    writeln("camera: WASD move, right mouse look, wheel zoom, Q/E roll, R reset roll");

    const captureFrame = screenshotFrame ? screenshotFrame : (frames ? frames : 1);
    uint frameIndex;
    double lastTime = glfwGetTime();

    while(!glfwWindowShouldClose(window) && (frames == 0 || frameIndex < frames))
    {
        ++frameIndex;
        glfwPollEvents();

        const now = glfwGetTime();
        const dt = cast(float) (now - lastTime < 0.1 ? now - lastTime : 0.1);
        lastTime = now;

        updateCamera(camera, window, dt);

        WorldTransformation wtb;
        wtb.model = Matrix4x4f.identity();
        wtb.view = camera.view;
        wtb.proj = vulkanPerspectiveMatrix(
            camera.fov,
            cast(float) scene.swapChain.imageExtent.width / scene.swapChain.imageExtent.height,
            nearPlane,
            farPlane,
        );

        scene.drawNextFrame((ref FrameBuilder fb, ref Frame frame) {
            {
                DefaultRenderPass.VariableData renderData;
                renderData.common.imageExtent = scene.swapChain.imageExtent;
                renderData.common.frameBuffer = frame.frameBuffer;
                scene.renderPass.updateData(renderData);
            }

            scene.updateFrameUniforms(frame, 0, wtb);
            godotScene.refreshBuffers(frame.commandBuffer);

            const modelViewProj = wtb.proj * wtb.view * wtb.model;


            if(screenshotPath.length && frameIndex == captureFrame)
                scene.captureFrame(screenshotPath);

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

        if(screenshotPath.length && frameIndex == captureFrame)
            writeln("screenshot saved to ", screenshotPath);
    }

    vkDeviceWaitIdle(device.device);
}
