import dlib.math: Matrix4x4f, Vector3f, Vector4f, scaleMatrix, translationMatrix;
import pukan;
import pukan.mover.component: MoverComponent;
import pukan.mover.quake: QuakeBody, QuakeCommand, QuakeMovementConfig;
import pukan.pbr.pipelines: plainShading;
import pukan.physics.simulation: Simulation;
import pukan.physics.world: CollisionWorld;
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

private CameraControls controls;
private bool cursorCaptured;
private double savedCursorX;
private double savedCursorY;

extern(C) void onCursorPos(GLFWwindow* window, double x, double y) nothrow @nogc
{
    controls.cursorMoved(x, y,
        glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS,
        glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_MIDDLE) == GLFW_PRESS);
}

extern(C) void onScroll(GLFWwindow*, double, double yoffset) nothrow @nogc
{
    controls.scroll(cast(float) yoffset);
}

void updateCamera(ref FlyCamera camera, GLFWwindow* window, float dt)
{
    bool pressed(int key) nothrow @nogc
    {
        return glfwGetKey(window, key) == GLFW_PRESS;
    }

    // A held look or pan button owns the cursor, so neither stops at a border
    const captured =
        glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS
        || glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_MIDDLE) == GLFW_PRESS;

    if(captured != cursorCaptured)
    {
        cursorCaptured = captured;
        controls.forgetCursor();

        if(captured)
        {
            glfwGetCursorPos(window, &savedCursorX, &savedCursorY);
            glfwSetInputMode(window, GLFW_CURSOR, GLFW_CURSOR_DISABLED);
        }
        else
        {
            glfwSetInputMode(window, GLFW_CURSOR, GLFW_CURSOR_NORMAL);
            glfwSetCursorPos(window, savedCursorX, savedCursorY);
        }
    }

    CameraControlState state;
    state.forward = pressed(GLFW_KEY_W);
    state.back = pressed(GLFW_KEY_S);
    state.left = pressed(GLFW_KEY_A);
    state.right = pressed(GLFW_KEY_D);
    state.rollLeft = pressed(GLFW_KEY_Q);
    state.rollRight = pressed(GLFW_KEY_E);
    state.fast = pressed(GLFW_KEY_LEFT_SHIFT) || pressed(GLFW_KEY_RIGHT_SHIFT);
    state.slow = pressed(GLFW_KEY_LEFT_ALT) || pressed(GLFW_KEY_RIGHT_ALT);
    state.resetRoll = pressed(GLFW_KEY_R);
    state.toggleLookAxis = pressed(GLFW_KEY_H);

    int viewportWidth;
    int viewportHeight;
    glfwGetWindowSize(window, &viewportWidth, &viewportHeight);
    state.viewportWidth = cast(float) viewportWidth;
    state.viewportHeight = cast(float) viewportHeight;

    const lookAxis = camera.lookAxis;
    controls.update(camera, state, dt);

    if(camera.lookAxis != lookAxis)
        writeln(camera.lookAxis == LookAxis.horizontal
            ? "look axis: horizontal (world up)"
            : "look axis: screen (camera up)");
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
    bool plainMode;
    bool offscreen;
    bool characterMode;
    bool thirdPerson;
    string spawnOption;
    bool walkForward;
    bool fixedStep;
    float physicsHz = 60.0f;
    float fovOption = cameraFov;
    float nearOption = cameraNear;
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
        "plain", "draw every surface in the plain lit mode", &plainMode,
        "offscreen", "render without a window, for screenshots and benchmarks", &offscreen,
        "character", "walk a Quake-style capsule through the level", &characterMode,
        "spawn", "character spawn position, x,y,z", &spawnOption,
        "walk", "hold forward, for headless movement tests", &walkForward,
        "fixed-step", "advance one physics tick per frame", &fixedStep,
        "third-person", "draw the character from behind", &thirdPerson,
        "physics-hz", "fixed character tick rate", &physicsHz,
        "fov", "vertical field of view in degrees", &fovOption,
        "near", "near clipping distance", &nearOption,
        "far", "far clipping distance", &farOption,
        "speed", "camera movement speed in units per second", &speedOption,
    );

    if(getoptResult.helpWanted)
    {
        defaultGetoptPrinter("pukan Godot scene demo", getoptResult.options);
        return;
    }

    plainShading = plainMode;

    if(offscreen && frames == 0)
        frames = 1;

    if(plainShading)
        writeln("plain shading: on");

    if(!offscreen)
        enforce(glfwInit());
    scope(exit)
    {
        if(!offscreen)
            glfwTerminate();
    }

    GLFWwindow* window;
    if(!offscreen)
    {
        enforce(glfwVulkanSupported());
        glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);

        window = glfwCreateWindow(width, height, "pukan Godot scene".toStringz, null, null);
        enforce(window, "Cannot create a window");
        glfwSetCursorPosCallback(window, &onCursorPos);
        glfwSetScrollCallback(window, &onScroll);
    }
    scope(exit)
    {
        if(window)
            glfwDestroyWindow(window);
    }

    const(char)*[] instanceExtensions = offscreen ? null : glfwExtraExtensions!appEntities();
    auto vk = Instance.createWith!appEntities("pukan Godot scene", 1, instanceExtensions);
    scope(exit) destroy(vk);

    VkSurfaceKHR surface;
    if(!offscreen)
    {
        static import glfw3.internal;
        glfwCreateWindowSurface(
            vk.instance,
            window,
            cast(glfw3.internal.VkAllocationCallbacks*) vk.allocator,
            cast(ulong*) &surface,
        );
    }

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
    if(!offscreen)
        filter.checks ~= DeviceCheck("surface", &surfaceCheck);

    auto selected = vk.findSuitablePhysicalDevice!appRequirements(filter);
    auto physDevice = selected.device();

    VkSurfaceFormatKHR surfaceFormat;
    if(!offscreen)
    {
        string surfaceReason;
        surfaceFormat = physDevice.chooseSurfaceFormat(surface, surfaceReason);
        enforce(surfaceFormat.format != VK_FORMAT_UNDEFINED, surfaceReason);
    }

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
        if(window is null)
            return;

        int w;
        int h;
        glfwGetFramebufferSize(window, &w, &h);

        while(w == 0 || h == 0)
        {
            glfwGetFramebufferSize(window, &w, &h);
            glfwWaitEvents();
        }
    }

    Scene scene;
    if(offscreen)
        scene = new Scene(device, VkExtent2D(width, height), VK_FORMAT_R8G8B8A8_SRGB);
    else
        scene = new Scene(device, surface, &windowSizeChanged, surfaceFormat);
    scope(exit) destroy(scene);

    scene.sunShadow.enabled = !noShadows;
    scene.sunShadow.cache = true;
    scene.godotFactory.preloadShadows = !noShadows;

    if(scenePath.length == 0 && packPath.length == 0)
        scenePath = characterMode
            ? "demo_godot/godot_samples/character/level.tscn"
            : "demo_godot/godot_samples/generated/procedural.tscn";

    auto godotScene = packPath.length
        ? scene.godotFactory.createPacked(packPath, scenePath)
        : scene.godotFactory.create(scenePath);
    scope(exit) destroy(godotScene);

    GlTF characterModel;
    Vector3f characterModelOffset;
    float characterModelScale = 1.0f;

    if(characterMode)
    {
        import std.file: exists;

        const modelPath = "demo_godot/godot_samples/platformer/enemy/enemy.glb";

        if(exists(modelPath))
            characterModel = scene.gltfFactory.create(modelPath);
    }
    scope(exit) if(characterModel) destroy(characterModel);
    writeln("loaded ", packPath.length ? packPath : scenePath, ": meshes ", godotScene.meshCount,
        ", geometries ", godotScene.geometryCount,
        ", nodes skipped ", godotScene.skippedNodes,
        ", resources skipped ", godotScene.skippedResources,
        ", lights ", godotScene.lights.length,
        ", instances ", godotScene.instanceCount,
        ", gltf assets ", scene.gltfFactory.cachedAssetCount);

    printSkippedTypes("nodes not rendered", godotScene.skippedNodeTypes);
    printSkippedTypes("resources not rendered", godotScene.skippedResourceTypes);

    auto collisionWorld = new CollisionWorld;
    godotScene.buildCollisionWorld(collisionWorld);
    writeln("colliders ", collisionWorld.colliderCount());

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

    if(characterModel)
    {
        characterModel.uploadToGPUImmediate(device, scene.frameBuilder.commandPool, *initialBuffer);

        const bounds = characterModel.calcAABB();

        if(bounds.min.y == bounds.min.y && bounds.max.y > bounds.min.y)
        {
            characterModelScale = 1.4f / (bounds.max.y - bounds.min.y);
            characterModelOffset = Vector3f(0, -bounds.min.y * characterModelScale, 0);
        }
    }

    scene.sunShadow.fit(godotScene.calcAABB());

    if(godotScene.environment.present)
    {
        const environment = godotScene.environment;

        final switch(environment.backgroundMode)
        {
            case GodotBackgroundMode.clearColor:
            case GodotBackgroundMode.color:
                scene.background.setColor(environment.backgroundColor, environment.backgroundEnergy);
                break;

            case GodotBackgroundMode.sky:
                if(environment.sky.present)
                    scene.background.setSky(
                        environment.sky.topColor,
                        environment.sky.horizonColor,
                        environment.sky.groundHorizonColor,
                        environment.sky.groundBottomColor,
                        environment.sky.energy,
                    );
                else
                    scene.background.setColor(environment.backgroundColor, environment.backgroundEnergy);
                break;

            case GodotBackgroundMode.canvas:
            case GodotBackgroundMode.keep:
            case GodotBackgroundMode.cameraFeed:
                break;
        }

        Vector3f ambientColor = environment.ambientColor;
        if(environment.ambientSource == GodotAmbientSource.background)
            ambientColor = environment.backgroundColor;

        scene.ambientLight = Vector4f(
            ambientColor.x,
            ambientColor.y,
            ambientColor.z,
            environment.ambientSource == GodotAmbientSource.disabled ? 0.0f : environment.ambientEnergy,
        );
        scene.exposure = environment.exposure;
        scene.tonemapMode = environment.tonemapMode;
        scene.tonemapWhite = environment.white;
    }

    Vector3f eye = Vector3f(0, 3.0f, -8.0f);
    Vector3f target = Vector3f(0, 1.5f, 0);

    if(eyeOption.length)
        eye = parseVector(eyeOption);
    if(targetOption.length)
        target = parseVector(targetOption);

    FlyCamera camera;
    float nearPlane = nearOption;
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

    QuakeBody characterBody;
    QuakeMovementConfig characterConfig;
    MoverComponent mover;
    QuakeCommand characterCommand;
    characterCommand.wishDir = Vector3f(0, 0, 0);
    characterCommand.wishSpeed = 0.0f;
    characterCommand.jump = false;

    Simulation simulation;

    if(characterMode)
    {
        Vector3f spawn = Vector3f(0, 2, 0);

        if(spawnOption.length)
            spawn = parseVector(spawnOption);
        else
        {
            Vector3f marker;

            if(godotScene.spawnPosition(marker))
                spawn = marker;
        }

        mover = new MoverComponent(collisionWorld, characterBody, characterConfig);
        mover.teleport(spawn);

        simulation = new Simulation(collisionWorld);
        simulation.setTickRate(physicsHz);
    }
    scope(exit) if(simulation) destroy(simulation);

    if(!offscreen)
        writeln(characterMode
            ? "character: WASD move, right mouse look, Space jump"
            : "camera: WASD move, right mouse look, middle mouse pan, wheel zoom, Q/E roll, R reset roll, H look axis (horizontal)");

    const captureFrame = screenshotFrame ? screenshotFrame : (frames ? frames : 1);
    uint frameIndex;
    import core.time: MonoTime;
    const start = MonoTime.currTime;
    double lastTime = offscreen ? 0.0 : glfwGetTime();
    double characterCursorX = 0.0;
    double characterCursorY = 0.0;
    bool characterCursorKnown;
    float characterMaxHeight = -float.infinity;

    while((offscreen ? frameIndex < frames : !glfwWindowShouldClose(window)) && (frames == 0 || frameIndex < frames))
    {
        ++frameIndex;
        if(!offscreen)
            glfwPollEvents();

        const now = offscreen ? (MonoTime.currTime - start).total!"msecs" * 0.001 : glfwGetTime();
        const measuredDt = cast(float) (now - lastTime < 0.1 ? now - lastTime : 0.1);
        const dt = fixedStep || offscreen
            ? cast(float) (1.0 / physicsHz)
            : measuredDt;
        lastTime = now;

        if(characterMode)
        {
            if(!offscreen)
            {
                bool pressed(int key) nothrow @nogc
                {
                    return glfwGetKey(window, key) == GLFW_PRESS;
                }

                double cursorX;
                double cursorY;
                glfwGetCursorPos(window, &cursorX, &cursorY);

                if(characterCursorKnown)
                {
                    const dx = cast(float) (cursorX - characterCursorX);
                    const dy = cast(float) (cursorY - characterCursorY);

                    if(glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS)
                        camera.look(dx, dy);
                }

                characterCursorX = cursorX;
                characterCursorY = cursorY;
                characterCursorKnown = true;

                Vector3f forward = camera.forward;
                forward.y = 0;

                if(forward.length > 1e-6f)
                    forward = forward.normalized;
                else
                    forward = Vector3f(0, 0, 0);

                Vector3f right = camera.right;
                right.y = 0;

                if(right.length > 1e-6f)
                    right = right.normalized;
                else
                    right = Vector3f(0, 0, 0);

                const forwardInput = (pressed(GLFW_KEY_W) ? 1.0f : 0.0f)
                    - (pressed(GLFW_KEY_S) ? 1.0f : 0.0f);
                const rightInput = (pressed(GLFW_KEY_D) ? 1.0f : 0.0f)
                    - (pressed(GLFW_KEY_A) ? 1.0f : 0.0f);
                const wish = forward * forwardInput + right * rightInput;

                characterCommand.wishDir = wish;
                characterCommand.wishSpeed = wish.length > 1e-6f
                    ? characterConfig.maxSpeed
                    : 0.0f;
                characterCommand.jump = pressed(GLFW_KEY_SPACE);
            }
            else
            {
                characterCommand.wishDir = Vector3f(0, 0, 0);
                characterCommand.wishSpeed = 0.0f;
                characterCommand.jump = false;
            }

            if(walkForward)
            {
                Vector3f forward = camera.forward;
                forward.y = 0;

                if(forward.length > 1e-6f)
                    forward = forward.normalized;
                else
                    forward = Vector3f(0, 0, 0);

                characterCommand.wishDir = forward;
                characterCommand.wishSpeed = characterConfig.maxSpeed;
            }

            simulation.step(dt, (tickDt) {
                mover.step(characterCommand, tickDt);
                characterMaxHeight = characterMaxHeight > mover.state.position.y
                    ? characterMaxHeight
                    : mover.state.position.y;
            });

            const alpha = simulation.interpolationAlpha();
            const eyePosition = mover.eyePosition(alpha);

            if(thirdPerson)
            {
                const back = -camera.forward;
                const desired = 6.0f;
                const hit = collisionWorld.raycast(eyePosition, back, desired,
                    characterBody.mask);
                const distance = hit.hit
                    ? (hit.t > 0.1f ? hit.t - 0.1f : 0.1f)
                    : desired;

                camera.position = eyePosition + back * distance;
            }
            else
                camera.position = eyePosition;
        }
        else if(!offscreen)
            updateCamera(camera, window, dt);

        Matrix4x4f characterTransform = Matrix4x4f.identity();

        if(characterMode && characterModel)
            characterTransform = scaleMatrix(Vector3f(characterModelScale, characterModelScale,
                characterModelScale)) * translationMatrix(
                    mover.renderPosition(simulation.interpolationAlpha()) + characterModelOffset);

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

            if(characterModel)
                characterModel.refreshBuffers(frame.commandBuffer);

            const modelViewProj = wtb.proj * wtb.view * wtb.model;


            if(screenshotPath.length && frameIndex == captureFrame)
                scene.captureFrame(screenshotPath);

            scene.recordCommandBuffer(
                frame,
                (buf, phase) {
                    godotScene.drawingBufferFilling(buf, modelViewProj, frame.frameSets[0].descriptorSet, phase);

                    if(characterModel && thirdPerson)
                        characterModel.drawingBufferFilling(buf, modelViewProj * characterTransform,
                            frame.frameSets[0].descriptorSet, phase);
                },
                null,
                (buf) {
                    godotScene.drawingBufferFilling(buf, scene.sunShadow.viewProj * wtb.model, frame.frameSets[0].descriptorSet, DrawPhase.shadow);
                },
            );
        });

        if(screenshotPath.length && frameIndex == captureFrame)
            writeln("screenshot saved to ", screenshotPath);
    }

    if(characterMode)
        writeln("character position ", mover.state.position,
            " max height ", characterMaxHeight,
            " onGround ", mover.state.onGround);

    vkDeviceWaitIdle(device.device);
}
