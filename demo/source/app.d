import arena: placeOnIcosahedron;
import orientation: createOrientationCube, orientationAtlasPath;
import pukan;
import pukan.gltf.loader: GltfLoadOptions;
import pukan.vulkan.renderpass: DrawPhase;
import pukan.graphics.g3d.material: runtimeMaterialOverride;
import pukan.graphics.g3d.pbr.pipelines: LightingMode, lightingMode;
import pukan.graphics.g3d.scene_tree;
import pukan.graphics.g3d.section: SectionPass;
import pukan.graphics.g3d.primitives_tree.cylinder: CylinderGroup, CylinderGroupFlag, CylinderGroupFlags, CylinderInstance, CylinderRenderer;
import pukan.graphics.g3d.primitives_tree.mesh: LitVertex;
import pukan.graphics.g3d.primitives_tree.sphere: SphereGroup, SphereInstance, SphereRenderer;
import pukan.vulkan.bindings;
import pukan.vulkan.core: FlightRecorder, LayerSettings;
import pukan.vulkan.textures: Texture;
import core.time: Duration, MonoTime;
import glfw3.api;
import std.algorithm: sort;
import std.datetime.stopwatch;
import std.exception;
import std.logger;
import std.meta: AliasSeq;
import std.path: buildPath;
import std.stdio;
import std.string: fromStringz, toStringz;

alias appRequirements = Requirements!(SwapChain, GltfFactory, FrameBuilder, SphereRenderer, CylinderRenderer, CullFrame);
debug alias DebugEntities = AliasSeq!(FlightRecorder, LayerSettings);
else alias DebugEntities = AliasSeq!();

alias appEntities = AliasSeq!(DebugEntities, WindowSurface);

/// GLFW extensions that the given app entities do not already declare
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

enum fps = 60;
enum width = 640;
enum height = 640;

void main(string[] args) {
    import std.getopt: defaultGetoptPrinter, getopt;

    bool stereo;
    bool crossEyed;
    bool bench;
    uint frames;
    bool core;
    bool noShadows;
    bool offscreen;
    bool occlusion;
    bool section;
    string sectionShapeOption = "plane";
    bool sectionFillSolid;
    double maxFps = 60;
    string presentModeOption;
    string materialMode = "authored";
    string[] sampleNames;
    string screenshotPath;
    string secondScreenshotPath;
    bool secondTarget;
    uint screenshotFrame;
    auto getoptResult = getopt(
        args,
        "stereo", "render side-by-side stereo", &stereo,
        "cross-eyed", "swap stereo halves for cross-eyed viewing", &crossEyed,
        "frames", "exit after N frames (0 = run forever)", &frames,
        "bench", "run the fixed benchmark scene and print metrics", &bench,
        "core", "ignore the KHR material extensions", &core,
        "no-shadows", "do not cast shadows", &noShadows,
        "offscreen", "render without a window, for screenshots and benchmarks", &offscreen,
        "occlusion", "build the coarse occlusion grid", &occlusion,
        "section", "cut the scene with a section on the first frame", &section,
        "section-shape", "plane, sphere or capsule (default: plane)", &sectionShapeOption,
        "section-fill", "fill the cut with a solid colour instead of a hatch", &sectionFillSolid,
        "max-fps", "cap frames per second, 0 = only vsync", &maxFps,
        "present-mode", "fifo, mailbox or immediate (default: fifo, bench: immediate)", &presentModeOption,
        "material-mode", "authored, pbr, lit or unlit", &materialMode,
        "sample", "show only this sample, repeatable", &sampleNames,
        "screenshot", "save the captured frame to this PNG", &screenshotPath,
        "second-target", "draw the scene into a second offscreen target", &secondTarget,
        "second-screenshot", "save the second target's frame to this PNG", &secondScreenshotPath,
        "screenshot-frame", "frame to capture (default: the last frame)", &screenshotFrame,
    );

    if(getoptResult.helpWanted)
    {
        defaultGetoptPrinter("pukan3D demo", getoptResult.options);
        return;
    }

    if(crossEyed)
        stereo = true;

    if(secondScreenshotPath.length)
        enforce(secondTarget, "--second-screenshot needs --second-target");

    benchMode = bench;
    if(benchMode)
    {
        if(frames == 0)
            frames = 300;

        sceneYaw = 0;
        scenePitch = 0;
        maxFps = 0;
    }

    if(offscreen && frames == 0)
        frames = 1;

    if(presentModeOption.length == 0)
        presentModeOption = benchMode ? "immediate" : "fifo";

    version(linux)
    version(DigitalMars)
    {
        import etc.linux.memoryerror;
        registerMemoryAssertHandler();
    }

    immutable name = "D/pukan3D/GLFW project";

    if(!offscreen)
        enforce(glfwInit());
    scope(exit)
    {
        if(!offscreen)
            glfwTerminate();
    }

    if(!offscreen)
    {
        enforce(glfwVulkanSupported());

        glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
        //~ glfwWindowHint(GLFW_RESIZABLE, GLFW_FALSE);

        if(benchMode)
        {
            glfwWindowHint(GLFW_RESIZABLE, GLFW_FALSE);
            glfwWindowHint(GLFW_FLOATING, GLFW_TRUE);
        }
    }

    GLFWwindow* window;
    if(!offscreen)
    {
        const windowWidth = stereo ? width * 2 : width;
        window = glfwCreateWindow(windowWidth, height, name.toStringz, null, null);
        enforce(window, "Cannot create a window");
        glfwSetScrollCallback(window, &onScroll);
        glfwSetMouseButtonCallback(window, &onMouseButton);
        glfwSetKeyCallback(window, &onKey);
        glfwSetCursorPosCallback(window, &onCursorPos);
        glfwGetCursorPos(window, &cursorX, &cursorY);
    }

    //~ glfwSetWindowUserPointer(demo.window, demo);
    //~ glfwSetWindowRefreshCallback(demo.window, &demo_refresh_callback);
    //~ glfwSetFramebufferSizeCallback(demo.window, &demo_resize_callback);
    //~ glfwSetKeyCallback(demo.window, &demo_key_callback);

    const(char)*[] instanceExtensions = offscreen ? null : glfwExtraExtensions!appEntities();
    auto vk = Instance.createWith!appEntities(name, 1, instanceExtensions);
    scope(exit) destroy(vk);

    //~ debug
    //~ {
        //~ writeln("Vulkan instance supported extensions:");
        //~ foreach(s; vk.extensions)
            //~ s.extensionName.to!string.writeln;
    //~ }

    //~ vk.printAllDevices();
    //~ vk.printAllAvailableLayers();

    VkSurfaceKHR surface;
    if(!offscreen)
    {
        static import glfw3.internal;
        glfwCreateWindowSurface(
            vk.instance.vk,
            window,
            cast(glfw3.internal.VkAllocationCallbacks*) vk.allocator,
            cast(ulong*) &surface
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
    //~ debug
    //~ {
        //~ writeln("");
        //~ writeln("Device supported extensions:");
        //~ foreach(s; physDevice.extensions)
            //~ s.extensionName.to!string.writeln;
    //~ }

    auto device = selected.createLogicalDevice!(Texture)();
    scope(exit)
    {
        import core.memory: GC;

        GC.collect();
        destroy(device);
    }

    debug auto dbg = vk.attachFlightRecorder(device);
    debug scope(exit) destroy(dbg);

    //~ vk.printSurfaceFormats(vk.devices[vk.deviceIdx], surface);
    //~ vk.printPresentModes(vk.devices[vk.deviceIdx], surface);

    void windowSizeChanged()
    {
        if(window is null)
            return;

        int width;
        int height;

        glfwGetFramebufferSize(window, &width, &height);

        while (width == 0 || height == 0)
        {
            /*
            TODO: I don't understand this logic, but it allowed to
            overcome refresh freezes when increasing the window size.
            Perhaps this code does not work as it should, but it is
            shown in this form in different articles.
            */

            glfwGetFramebufferSize(window, &width, &height);
            glfwWaitEvents();
        }
    }

    Scene scene;
    if(offscreen)
        scene = new Scene(device, VkExtent2D(stereo ? width * 2 : width, height), VK_FORMAT_R8G8B8A8_SRGB, "demo");
    else
        scene = new Scene(
            device,
            surface,
            &windowSizeChanged,
            surfaceFormat,
            "demo",
            parsePresentMode(presentModeOption),
        );
    scope(exit) destroy(scene);

    scene.frameRateLimit = maxFps;

    if(occlusion)
        scene.enableOcclusionDepth(192, 144);

    RenderTarget secondTargetHandle;
    if(secondTarget)
    {
        enforce(!stereo, "--second-target does not combine with --stereo");
        secondTargetHandle = scene.addOffscreenTarget(scene.swapChain.imageExtent);
    }

    sectionPass = new SectionPass(scene.pipelineFactory, scene.renderPass);
    sectionPass.enabled = section;
    sectionPass.mode = parseSectionShape(sectionShapeOption);
    sectionPass.fill = sectionFillSolid ? 1.0f : 0.0f;
    scene.customPass = sectionPass;
    sectionChanged = section && !benchMode && !offscreen;

    shadowsOn = !noShadows;
    scene.gltfFactory.preloadShadows = shadowsOn;

    camera = FlyCamera.lookingAt(
        Vector3f(0, 0.2f, -initialCameraDistance),
        Vector3f(0, 0, 0),
        scene.up,
    );
    camera.fov = cameraFovY;
    camera.speed = 1.0f;

    if(!benchMode && !offscreen)
    {
        writeln("camera: WASD move, right mouse look, middle mouse pan, wheel zoom, Q/E roll, R reset roll, H look axis (horizontal)");
        writeln("section: X toggle, C shape, F fill, [ ] radius");
    }

    scene.addPointLight(Vector3f(0.9f, 0.35f, 1.1f), Vector3f(1.0f, 0.25f, 0.15f) * 6.0f, 4.0f);
    scene.addPointLight(Vector3f(-0.8f, 0.4f, 0.8f), Vector3f(0.15f, 0.45f, 1.0f) * 6.0f, 4.0f);
    scene.addPointLight(Vector3f(0.0f, 1.1f, 1.4f), Vector3f(0.3f, 0.9f, 0.35f) * 4.0f, 5.0f);

    scene.addSpotLight(
        Vector3f(0.0f, 0.8f, -1.6f),
        Vector3f(0.0f, -0.15f, 1.0f),
        Vector3f(1.0f, 0.9f, 0.75f) * 6.0f,
        8.0f,
        18f.degtorad,
        32f.degtorad,
    );


    {
        GltfLoadOptions loadOptions;
        loadOptions.extensions = !core;

        switch(materialMode)
        {
            case "authored":
                break;
            case "pbr":
                loadOptions.modeOverride = cast(int) MaterialMode.pbr;
                break;
            case "lit":
                loadOptions.modeOverride = cast(int) MaterialMode.lit;
                break;
            case "unlit":
                loadOptions.modeOverride = cast(int) MaterialMode.unlit;
                break;
            default:
                enforce(false, "unknown material mode: " ~ materialMode);
        }

        scene.gltfFactory.loadOptions = loadOptions;
    }

    //TODO: remove
    auto frameBuilder = &scene.frameBuilder;

    // Using any (of first frame, for example) buffer as buffer for initial loading
    auto initBuf = &scene.swapChain.frames[0].commandBuffer();

    Bone* cubeRotator;
    Bone* litCubeRotator;
    LineRenderer extendedLine;
    LineRenderer overlayLine;
    scope tree = createDemoTree(device, scene, *frameBuilder, *initBuf, cubeRotator, litCubeRotator, extendedLine, overlayLine);
    scope(exit) tree.destroy;

    auto startupStart = MonoTime.currTime;

    GlTF[] arenaGltfs;
    {
        auto trans = Vector3f(0, 0, 0).translationMatrix;
        auto arenaNode = tree.addChild(Bone(mat: trans));
        auto samples = benchMode ? benchSampleNames : (sampleNames.length ? sampleNames : null);
        arenaGltfs = createArena(scene, arenaNode, samples, samples.length == 1 ? 0.8f : 0.1f);
    }

    static if(runtimeMaterialOverride)
        overrideTargets = arenaGltfs;

    tree.uploadToGPUImmediate(device, frameBuilder.commandPool, *initBuf);

    const startupWallNs = cast(ulong) (MonoTime.currTime - startupStart).total!"nsecs";

    LoadStats startupStats;
    foreach(ref gltf; arenaGltfs)
    {
        startupStats.readNs += gltf.loadStats.readNs;
        startupStats.parseNs += gltf.loadStats.parseNs;
        startupStats.decodeNs += gltf.loadStats.decodeNs;
        startupStats.uploadNs += gltf.loadStats.uploadNs;
    }

    import pukan.exceptions;

    auto sw = StopWatch(AutoStart.yes);

    writeln(); // empty line for FPS counter

    ulong[] benchFrameNs;
    ulong[] benchUpdateNs;

    const captureFrame = screenshotFrame ? screenshotFrame : (frames ? frames : 1);

    // Main loop
    uint frameCount;
    while ((offscreen ? frameCount < frames : !glfwWindowShouldClose(window)) && (frames == 0 || frameCount < frames))
    {
        frameCount++;

        const frameStart = sw.peek;

        if(benchMode && frameCount == benchWarmupFrames + 1)
            device.resetUploadedBytes();

        if(!offscreen)
            glfwPollEvents();

        const curr = sw.peek.total!"msecs" * 0.001;
        frameTime = offscreen ? curr : glfwGetTime();

        static float prevCurr = 0.0f;
        const dt = curr - prevCurr;
        prevCurr = curr;

        if(!benchMode && !sceneDragging && interactionTimer.idleFor(frameTime, autoResumeDelay))
            sceneYaw += autoRotationSpeed * dt;

        if(!offscreen && !benchMode)
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

            CameraControlState controlState;
            controlState.forward = pressed(GLFW_KEY_W);
            controlState.back = pressed(GLFW_KEY_S);
            controlState.left = pressed(GLFW_KEY_A);
            controlState.right = pressed(GLFW_KEY_D);
            controlState.rollLeft = pressed(GLFW_KEY_Q);
            controlState.rollRight = pressed(GLFW_KEY_E);
            controlState.fast = pressed(GLFW_KEY_LEFT_SHIFT) || pressed(GLFW_KEY_RIGHT_SHIFT);
            controlState.slow = pressed(GLFW_KEY_LEFT_ALT) || pressed(GLFW_KEY_RIGHT_ALT);
            controlState.resetRoll = pressed(GLFW_KEY_R);
            controlState.toggleLookAxis = pressed(GLFW_KEY_H);

            int viewportWidth;
            int viewportHeight;
            glfwGetWindowSize(window, &viewportWidth, &viewportHeight);
            controlState.viewportWidth = cast(float) viewportWidth;
            controlState.viewportHeight = cast(float) viewportHeight;

            const lookAxis = camera.lookAxis;
            controls.update(camera, controlState, dt);

            if(camera.lookAxis != lookAxis)
                writefln("look axis: %s", camera.lookAxis == LookAxis.horizontal
                    ? "horizontal (world up)"
                    : "screen (camera up)");
        }

        ulong entityUpdateNs;

        WorldTransformation wtb;
        const updateStart = sw.peek;
        updateWorldTransformations(
            wtb,
            benchMode ? cast(float) frameCount / 60.0f : curr,
            scene.swapChain.imageExtent,
            tree,
            cubeRotator,
            litCubeRotator,
        );
        entityUpdateNs += cast(ulong) (sw.peek - updateStart).total!"nsecs";

        if(skyChanged)
        {
            skyChanged = false;
            writefln("lighting: %s", lightingMode);
        }

        scene.sunShadow.enabled = shadowsOn;

        if(shadowsChanged)
        {
            shadowsChanged = false;
            writefln("shadows: %s", shadowsOn ? "on" : "off");
        }

        if(sectionChanged)
        {
            sectionChanged = false;
            writefln(
                "section: %s, shape: %s, fill: %s, radius: %.2f",
                sectionPass.enabled ? "on" : "off",
                sectionShapeName(sectionPass.mode),
                sectionPass.fill > 0.5f ? "solid" : "hatch",
                sectionRadius,
            );
        }

        static if(runtimeMaterialOverride)
        {
            if(overrideChanged)
            {
                overrideChanged = false;

                const overrideMaterial = Material(Vector3f(0.95f, 0.45f, 0.1f), MaterialMode.unlit);

                foreach(target; overrideTargets)
                    if(materialOverridden)
                        target.setMaterialOverride(overrideMaterial);
                    else
                        target.clearMaterialOverride();

                writefln("material override: %s", materialOverridden);
            }
        }

        if(screenshotPath.length && frameCount == captureFrame)
            scene.captureFrame(screenshotPath);

        if(secondScreenshotPath.length && frameCount == captureFrame)
            scene.captureFrame(secondTargetHandle, secondScreenshotPath);

        scene.drawNextFrame((ref FrameBuilder fb, ref Frame frame, RenderTarget renderTarget) {

            {
                DefaultRenderPass.VariableData renderData;
                renderData.common.imageExtent = renderTarget.extent;
                renderData.common.frameBuffer = frame.frameBuffer;
                scene.renderPass.updateData(renderData);
            }

            auto cb = frame.commandBuffer;
            const firstTarget = renderTarget is scene.targets[0];

            // A second target looks at the arena from its own camera
            WorldTransformation targetWtb = wtb;
            Vector3f targetForward = camera.forward;

            if(!firstTarget)
            {
                const eye = Vector3f(3.0f, 1.2f, -2.5f);
                const focus = Vector3f(0, 0.2f, 0);
                const aspect = cast(float) renderTarget.extent.width / renderTarget.extent.height;

                targetWtb.view = cameraView(eye, focus, camera.up);
                targetWtb.proj = vulkanPerspectiveMatrix(camera.fov, aspect, cameraNear, cameraFar);
                targetForward = (focus - eye).normalized;
            }

            const targetTransl = targetWtb.proj * targetWtb.view * targetWtb.model;
            const targetAspect = cast(float) renderTarget.extent.width / renderTarget.extent.height;

            scene.sphereRenderer.setCamera(
                targetWtb.view * targetWtb.model * Vector3f(0, 0, sceneDepth).translationMatrix,
                camera.fov,
                targetAspect,
                renderTarget.extent.height,
                cameraNear,
                cameraFar,
            );

            scene.cylinderRenderer.setCamera(
                targetWtb.view * targetWtb.model,
                camera.fov,
                targetAspect,
                renderTarget.extent.height,
                cameraNear,
                cameraFar,
            );

            extendedLine.setViewport(renderTarget.extent);
            overlayLine.setViewport(renderTarget.extent);

            if(sectionPass !is null && sectionPass.enabled)
            {
                const focus4 = Vector4f(0, 0, 0, 1) * targetWtb.model;
                const focus = Vector3f(
                    cast(float) focus4.x,
                    cast(float) focus4.y,
                    cast(float) focus4.z,
                );

                if(sectionPass.mode == 0)
                {
                    const offset = -(targetForward.x * focus.x + targetForward.y * focus.y + targetForward.z * focus.z);
                    sectionPass.shape = Vector4f(targetForward.x, targetForward.y, targetForward.z, offset);
                }
                else
                    sectionPass.shape = Vector4f(focus.x, focus.y, focus.z, sectionRadius);

                const clip = Vector4f(focus.x, focus.y, focus.z, 1) * (targetWtb.proj * targetWtb.view);
                sectionPass.ndcZ = cast(float) (clip.z / clip.w);
            }

            if(firstTarget)
            {
                scene.sphereRenderer.prepare(cb);
                scene.cylinderRenderer.prepare(cb);

                const entityStart = sw.peek;
                tree.forEachDrawablePayload((d) => d.refreshBuffers(cb));
                entityUpdateNs += cast(ulong) (sw.peek - entityStart).total!"nsecs";
            }

            if(stereo)
            {
                // The sun's cascades come from the base view, so every eye
                // draws with the map the shadow pass filled
                scene.updateFrameUniforms(frame, 0, wtb);

                SceneView[2] views = SceneView.stereo(scene.swapChain.imageExtent, crossEyed);
                bool[2] uniformsSet;

                scene.recordCommandBuffer(
                    frame,
                    views[],
                    (buf, view, layout, phase) {
                        auto stereoWtb = calculateStereoWTB(layout.area.extent);
                        tree.root.payload = Bone(stereoWtb[layout.frameSet].proj * stereoWtb[layout.frameSet].view * stereoWtb[layout.frameSet].model);

                        if(!uniformsSet[layout.frameSet])
                        {
                            uniformsSet[layout.frameSet] = true;
                            scene.updateFrameUniforms(frame, layout.frameSet, stereoWtb[layout.frameSet], false);
                        }

                        tree.drawingBufferFilling(buf, Matrix4x4f.identity, frame.frameSets[layout.frameSet].descriptorSet, phase);
                    },
                    (buf, view, layout, phase) {
                        auto stereoWtb = calculateStereoWTB(layout.area.extent);
                        tree.root.payload = Bone(stereoWtb[layout.frameSet].proj * stereoWtb[layout.frameSet].view * stereoWtb[layout.frameSet].model);
                        tree.drawingBufferFilling(buf, Matrix4x4f.identity, frame.frameSets[layout.frameSet].descriptorSet, phase);
                    },
                    (buf, cascade) {
                        tree.root.payload = Bone(scene.sunShadow.cascades.viewProj[cascade] * wtb.model);
                        tree.drawingBufferFilling(buf, Matrix4x4f.identity, frame.frameSets[0].descriptorSet, DrawPhase.shadow);
                    },
                );
            }
            else
            {
                scene.updateFrameUniforms(frame, 0, targetWtb);

                scene.recordCommandBuffer(
                    frame,
                    (buf, view, layout, phase) {
                        tree.root.payload = Bone(targetTransl);
                        tree.drawingBufferFilling(buf, Matrix4x4f.identity, frame.frameSets[0].descriptorSet, phase);
                    },
                    (buf, view, layout, phase) {
                        tree.root.payload = Bone(targetTransl);
                        tree.drawingBufferFilling(buf, Matrix4x4f.identity, frame.frameSets[0].descriptorSet, phase);
                    },
                    (buf, cascade) {
                        tree.root.payload = Bone(scene.sunShadow.cascades.viewProj[cascade] * targetWtb.model);
                        tree.drawingBufferFilling(buf, Matrix4x4f.identity, frame.frameSets[0].descriptorSet, DrawPhase.shadow);
                    },
                );
            }
        });

        if(screenshotPath.length && frameCount == captureFrame)
            writeln("screenshot saved to ", screenshotPath);

        const frameEnd = sw.peek;

        if(benchMode && frameCount > benchWarmupFrames)
        {
            benchFrameNs ~= cast(ulong) (frameEnd - frameStart).total!"nsecs";
            benchUpdateNs ~= entityUpdateNs;
        }

        version(asset)
        {
            static size_t verifyFrameIdx;

            if(arenaGltfs.length && verifyFrameIdx % 25 == 0)
            {
                verifyFrameIdx++;
                import pukan.gltf: SkinnedGlTF_skinJointsGPU;

                foreach(a; arenaGltfs)
                {
                    if(auto s = cast(SkinnedGlTF_skinJointsGPU) a)
                    {
                        auto cb = frameBuilder.commandPool.allocateBuffers(1)[0];
                        scope(exit) frameBuilder.commandPool.freeBuffers([cb]);
                        s.debugVerifySkinJoints(device, frameBuilder.commandPool, cb);
                    }
                }
            }
        }

        if(!offscreen && !benchMode)
        {
            static size_t frameNum;
            static size_t fps;

            frameNum++;
            write("\rFPS: ", fps, ", frame: ", frameNum, ", currentFrameIdx: ", scene.swapChain.currentFrameIdx, ", ");

            static Duration prevTime;
            const now = sw.peek;

            if(prevTime.split!"seconds" != now.split!"seconds")
            {
                static size_t prevSecondFrameNum;
                fps = frameNum - prevSecondFrameNum;
                prevSecondFrameNum = frameNum;
            }

            prevTime = now;
        }
    }

    vkDeviceWaitIdle(device.device);

    if(benchMode)
        printBench(device, scene, benchFrameNs, benchUpdateNs, startupStats, startupWallNs);
}

private string sectionShapeName(uint mode)
{
    switch(mode)
    {
        case 1: return "sphere";
        case 2: return "capsule";
        default: return "plane";
    }
}

private uint parseSectionShape(string name)
{
    switch(name)
    {
        case "plane": return 0;
        case "sphere": return 1;
        case "capsule": return 2;
        default:
            enforce(false, "unknown section shape: " ~ name ~ " (plane, sphere, capsule)");
            assert(false);
    }
}

private VkPresentModeKHR parsePresentMode(string name)
{
    switch(name)
    {
        case "fifo": return VK_PRESENT_MODE_FIFO_KHR;
        case "mailbox": return VK_PRESENT_MODE_MAILBOX_KHR;
        case "immediate": return VK_PRESENT_MODE_IMMEDIATE_KHR;
        default:
            enforce(false, "unknown present mode: " ~ name ~ " (fifo, mailbox, immediate)");
            assert(false);
    }
}

private string presentModeName(VkPresentModeKHR mode)
{
    switch(mode)
    {
        case VK_PRESENT_MODE_IMMEDIATE_KHR: return "immediate";
        case VK_PRESENT_MODE_MAILBOX_KHR: return "mailbox";
        case VK_PRESENT_MODE_FIFO_KHR: return "fifo";
        case VK_PRESENT_MODE_FIFO_RELAXED_KHR: return "fifo_relaxed";
        default: return "unknown";
    }
}

private void printBench(LogicalDevice device, Scene scene, ulong[] frameNs, ulong[] updateNs, LoadStats startStats, ulong startWallNs)
{
    enforce(frameNs.length > 0, "BENCH no measured frames");

    double averageMs(ulong[] values)
    {
        ulong total;
        foreach(v; values)
            total += v;
        return cast(double) total / values.length / 1_000_000.0;
    }

    ulong percentile(ulong[] values, double p)
    {
        auto sorted = values.dup;
        sorted.sort;
        return sorted[cast(size_t) (p * (sorted.length - 1))];
    }

    writefln(
        "BENCH samples=%d frames=%d warmup=%d",
        benchSampleNames.length,
        frameNs.length,
        benchWarmupFrames,
    );
    writefln(
        "BENCH resolution=%dx%d present=%s",
        scene.swapChain.imageExtent.width,
        scene.swapChain.imageExtent.height,
        presentModeName(scene.swapChain.presentMode),
    );
    writefln("BENCH device=%s", fromStringz(device.physicalDevice.properties.deviceName.ptr));
    writefln(
        "BENCH vram_device_local_bytes=%d vram_host_visible_bytes=%d allocations=%d",
        device.deviceLocalMemoryBytes(),
        device.hostVisibleMemoryBytes(),
        device.deviceMemoryAllocationCount(),
    );
    writefln(
        "BENCH upload_bytes_per_frame=%.1f",
        cast(double) device.uploadedBytes() / frameNs.length,
    );
    writefln(
        "BENCH frame_ms avg=%.3f p50=%.3f p95=%.3f",
        averageMs(frameNs),
        percentile(frameNs, 0.5) / 1_000_000.0,
        percentile(frameNs, 0.95) / 1_000_000.0,
    );
    writefln(
        "BENCH update_ms avg=%.3f p50=%.3f p95=%.3f",
        averageMs(updateNs),
        percentile(updateNs, 0.5) / 1_000_000.0,
        percentile(updateNs, 0.95) / 1_000_000.0,
    );
    writefln(
        "BENCH start_ms read=%.3f parse=%.3f decode=%.3f upload=%.3f wall=%.3f",
        startStats.readNs / 1_000_000.0,
        startStats.parseNs / 1_000_000.0,
        startStats.decodeNs / 1_000_000.0,
        startStats.uploadNs / 1_000_000.0,
        startWallNs / 1_000_000.0,
    );
}

import dlib.math;

enum cameraFovY = 45.0f;
enum cameraNear = 0.01f;
enum cameraFar = 10.0f;
enum stereoEyeSeparation = 0.06f;
enum initialCameraDistance = 2.2f;
enum sceneDepth = 1.0f;

bool benchMode;
enum benchWarmupFrames = 30;

private string[] benchSampleNames = [
    "AnimatedCube",
    "Avocado",
    "BarramundiFish",
    "BoxTexturedNonPowerOfTwo",
    "CesiumMan",
    "CesiumMilkTruck",
    "Fox",
    "MandarinOrange",
    "Palka",
    "SimpleMeshes",
    "SimpleTexture",
];

FlyCamera camera;
CameraControls controls;
bool cursorCaptured;
double savedCursorX;
double savedCursorY;

bool skyChanged;
bool shadowsOn = true;
bool shadowsChanged;

SectionPass sectionPass;
bool sectionChanged;
float sectionRadius = 0.55f;

static if(runtimeMaterialOverride)
{
    bool materialOverridden;
    bool overrideChanged;
    GlTF[] overrideTargets;
}

extern(C) void onKey(GLFWwindow*, int key, int, int action, int) nothrow @nogc
{
    if(benchMode || action != GLFW_PRESS)
        return;

    interactionTimer.touch(frameTime);

    if(key == GLFW_KEY_L)
    {
        lightingMode = lightingMode == LightingMode.ibl ? LightingMode.analytic
            : lightingMode == LightingMode.analytic ? LightingMode.none
            : lightingMode == LightingMode.none ? LightingMode.unlit
            : LightingMode.ibl;

        skyChanged = true;
    }
    else
    {
        static if(runtimeMaterialOverride)
            if(key == GLFW_KEY_O)
            {
                materialOverridden = !materialOverridden;
                overrideChanged = true;
            }

        if(key == GLFW_KEY_T)
        {
            shadowsOn = !shadowsOn;
            shadowsChanged = true;
        }

        if(sectionPass !is null)
        {
            if(key == GLFW_KEY_X)
            {
                sectionPass.enabled = !sectionPass.enabled;
                sectionChanged = true;
            }
            else if(key == GLFW_KEY_C)
            {
                sectionPass.mode = (sectionPass.mode + 1) % 3;
                sectionChanged = true;
            }
            else if(key == GLFW_KEY_F)
            {
                sectionPass.fill = sectionPass.fill > 0.5f ? 0.0f : 1.0f;
                sectionChanged = true;
            }
            else if(key == GLFW_KEY_LEFT_BRACKET)
            {
                sectionRadius = sectionRadius > 0.05f ? sectionRadius - 0.05f : 0.05f;
                sectionChanged = true;
            }
            else if(key == GLFW_KEY_RIGHT_BRACKET)
            {
                sectionRadius = sectionRadius < 1.0f ? sectionRadius + 0.05f : 1.0f;
                sectionChanged = true;
            }
        }
    }
}

extern(C) void onScroll(GLFWwindow*, double, double yoffset) nothrow @nogc
{
    if(benchMode)
        return;

    controls.scroll(cast(float) yoffset);
    interactionTimer.touch(frameTime);
}

/// Last input time, so the auto rotation can resume on its own
struct InteractionTimer
{
    private double lastInput = -1e9;

    void touch(double now) nothrow @nogc
    {
        lastInput = now;
    }

    bool idleFor(double now, double delay) const nothrow @nogc
    {
        return now - lastInput > delay;
    }
}

InteractionTimer interactionTimer;

enum autoRotationSpeed = 90f.degtorad * 0.1f;
enum autoResumeDelay = 10.0;
enum manualRotationSensitivity = 0.006f;
enum maxScenePitch = 80f.degtorad;

double frameTime;
double cursorX;
double cursorY;
bool sceneDragging;
float sceneYaw = 0.0f;
float scenePitch = 0.0f;

extern(C) void onMouseButton(GLFWwindow*, int button, int action, int) nothrow @nogc
{
    if(benchMode)
        return;

    interactionTimer.touch(frameTime);

    if(button == GLFW_MOUSE_BUTTON_LEFT)
    {
        if(action == GLFW_PRESS)
            sceneDragging = true;
        else if(action == GLFW_RELEASE)
            sceneDragging = false;
    }
}

extern(C) void onCursorPos(GLFWwindow* window, double xpos, double ypos) nothrow @nogc
{
    if(benchMode)
        return;

    const look = glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS;
    const pan = glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_MIDDLE) == GLFW_PRESS;

    controls.cursorMoved(xpos, ypos, look, pan);

    const dx = xpos - cursorX;
    const dy = ypos - cursorY;
    cursorX = xpos;
    cursorY = ypos;

    if(look || pan)
        interactionTimer.touch(frameTime);

    if(!sceneDragging)
        return;

    interactionTimer.touch(frameTime);

    sceneYaw -= cast(float) dx * manualRotationSensitivity;
    scenePitch -= cast(float) dy * manualRotationSensitivity;

    if(scenePitch > maxScenePitch)
        scenePitch = maxScenePitch;
    if(scenePitch < -maxScenePitch)
        scenePitch = -maxScenePitch;
}

WorldTransformation calculateWTB(in VkExtent2D imageExtent)
{
    WorldTransformation wtb;

    wtb.model = rotationMatrix!float(Axis.y, sceneYaw) * rotationMatrix!float(Axis.x, scenePitch);
    wtb.view = camera.view;
    wtb.proj = vulkanPerspectiveMatrix(
        camera.fov,
        cast(float) imageExtent.width / imageExtent.height,
        cameraNear, cameraFar,
    );

    return wtb;
}

WorldTransformation[2] calculateStereoWTB(in VkExtent2D eyeExtent)
{
    auto base = calculateWTB(eyeExtent);
    const views = makeStereoViews(
        camera.position,
        camera.position + camera.forward * initialCameraDistance,
        camera.up,
        camera.fov,
        eyeExtent,
        cameraNear,
        cameraFar,
        stereoEyeSeparation,
    );

    WorldTransformation[2] ret;

    foreach(i; 0 .. 2)
    {
        ret[i] = base;
        ret[i].view = views[i].view;
        ret[i].proj = views[i].proj;
    }

    return ret;
}

void updateWorldTransformations(
    out WorldTransformation wtb,
    float curr,
    in VkExtent2D imageExtent,
    SceneTree tree,
    Bone* cubeRotator,
    Bone* litCubeRotator,
)
{
    wtb = calculateWTB(imageExtent);

    auto cubeRotation = rotationQuaternion(Vector3f(0, 1, 0), 90f.degtorad * curr * 0.5);
    *cubeRotator = Bone(cubeRotation.toMatrix4x4);

    if(litCubeRotator)
        *litCubeRotator = Bone(rotationMatrix!float(Axis.x, 0.4f) * cubeRotation.toMatrix4x4);
}

private string[] gltfFilesSearch(string dir, string[] only = null)
{
    import std.file;

    string[] found;

    if(only.length)
    {
        foreach(name; only)
        {
            auto sampleDir = buildPath(dir, name);
            if(!exists(sampleDir))
                continue;

            auto glbs = dirEntries(sampleDir, "*.glb", SpanMode.depth);
            if(!glbs.empty)
            {
                found ~= glbs.front;
                continue;
            }

            auto gltfs = dirEntries(sampleDir, "*.gltf", SpanMode.depth);
            if(!gltfs.empty)
                found ~= gltfs.front;
        }

        return found;
    }

    auto samples = dirEntries(dir, "*", SpanMode.shallow);
    foreach(sample_dir; samples)
    {
        if(!sample_dir.isDir)
            continue;

        auto glbs = dirEntries(sample_dir, "*.glb", SpanMode.depth);
        if(!glbs.empty)
        {
            found ~= glbs.front;
            continue;
        }

        auto gltfs = dirEntries(sample_dir, "*.gltf", SpanMode.depth);
        if(!gltfs.empty)
            found ~= gltfs.front;
    }

    return found;
}

GlTF[] createArena(T)(Scene scene, ref T node, string[] sampleNames = null, float targetSize = 0.1f)
{
    import std.parallelism: taskPool;

    const found = gltfFilesSearch("demo/assets/gltf_samples/", sampleNames);

    if(found.length == 0)
        return null;

    GlTF[] loaded;
    loaded.length = found.length;

    foreach(i, filename; taskPool.parallel(found, 1))
        loaded[i] = scene.gltfFactory.create(filename);

    CommandPool[] commandPools;
    commandPools.length = loaded.length;

    foreach(ref commandPool; commandPools)
        commandPool = scene.device.createCommandPool();

    scope(exit)
        foreach(ref commandPool; commandPools)
            destroy(commandPool);

    foreach(i, ref obj; taskPool.parallel(loaded, 1))
    {
        auto commandBuffers = commandPools[i].allocateBuffers(1);
        scope(exit) commandPools[i].freeBuffers(commandBuffers);

        obj.uploadToGPUImmediate(scene.device, commandPools[i], commandBuffers[0]);
    }

    placeOnIcosahedron(node, loaded, targetSize);

    return loaded;
}

private struct SphereSpec
{
    Vector3f color;
    uint cols;
    uint rows;
    float radius;
    float xStep;
    float yStep;
    float y0;
    MaterialMode mode = MaterialMode.lit;
}

auto createDemoTree(
    LogicalDevice device,
    Scene scene,
    FrameBuilder frameBuilder,
    scope VkCommandBuffer commandBuffer,
    out Bone* cubeRotator,
    out Bone* litCubeRotator,
    out LineRenderer extendedLine,
    out LineRenderer overlayLine,
)
{
    auto tree = new SceneTree;

    // Added first so it is traversed and drawn last
    auto overlayTree = new PrimitivesTree;
    tree.addChild(overlayTree);

    auto primitTree = new PrimitivesTree;

    {
        auto trans = Vector3f(0, 0, sceneDepth).translationMatrix;
        tree
            .addChild(Bone(mat: trans))
            .addChild(primitTree);
    }

    auto coloredBranch = primitTree.addChild(scene.coloredMeshFactory.graphicsPipelineCfg);
    coloredBranch.addChild(ShadowPipelineCfg(scene.coloredMeshFactory.shadowGraphicsPipelineCfg));

    {
        auto v = createCubeVertices;
        auto cube = scene.coloredMeshFactory.create(scene.frameBuilder, v[0], v[1]);

        auto n = coloredBranch.addChild(Bone());
        cubeRotator = n.payload.peek!Bone;

        n.addChild(cast(DrawablePrimitive) cube);
    }

    if(!benchMode)
    {
        auto litBranch = primitTree.addChild(scene.litMeshFactory.graphicsPipelineCfg);
        litBranch.addChild(ShadowPipelineCfg(scene.litMeshFactory.shadowGraphicsPipelineCfg));
        auto v = createLitCubeVertices;
        auto cube = scene.litMeshFactory.create(scene.frameBuilder, v[0], v[1]);

        auto material = Material(Vector3f(0.9f, 0.55f, 0.2f), MaterialMode.pbr);
        material.metallic = 0.1f;
        material.roughness = 0.35f;
        cube.setMaterial(material);

        auto rotator = litBranch
            .addChild(Bone(mat: Vector3f(0.5f, 0.0f, 0.0f).translationMatrix))
            .addChild(Bone(mat: rotationMatrix!float(Axis.x, 0.4f)));

        litCubeRotator = rotator.payload.peek!Bone;
        rotator.addChild(cast(DrawablePrimitive) cube);
    }

    auto textureBranch = primitTree.addChild(scene.texturedMeshFactory.graphicsPipelineCfg);
    textureBranch.addChild(ShadowPipelineCfg(scene.texturedMeshFactory.shadowGraphicsPipelineCfg));

    {
        VkFormat format;
        auto extFormatImg = loadImageFromFile("demo/assets/texture.jpeg", format);

        VkSamplerCreateInfo samplerInfo;
        {
            samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
            samplerInfo.magFilter = VK_FILTER_LINEAR;
            samplerInfo.minFilter = VK_FILTER_LINEAR;
            samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_REPEAT;
            samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_REPEAT;
            samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_REPEAT;
            samplerInfo.anisotropyEnable = VK_TRUE;
            samplerInfo.maxAnisotropy = requiredAnisotropy;
            samplerInfo.borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK;
            samplerInfo.unnormalizedCoordinates = VK_FALSE;
            samplerInfo.compareEnable = VK_FALSE;
            samplerInfo.compareOp = VK_COMPARE_OP_ALWAYS;
            samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
        }

        auto img = loadImageToMemory(device, frameBuilder.commandPool, commandBuffer, extFormatImg, format);
        auto texture = device.create!Texture(img, samplerInfo);
        auto mesh = scene.texturedMeshFactory.create(scene.frameBuilder, texturedVertices, texturedIndices, texture);

        textureBranch.addChild(cast(DrawablePrimitive) mesh);
    }

    {
        VkFormat format;
        auto extFormatImg = loadImageFromFile(orientationAtlasPath, format);

        VkSamplerCreateInfo samplerInfo;
        {
            samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
            samplerInfo.magFilter = VK_FILTER_LINEAR;
            samplerInfo.minFilter = VK_FILTER_LINEAR;
            samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            samplerInfo.borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK;
            samplerInfo.unnormalizedCoordinates = VK_FALSE;
            samplerInfo.compareEnable = VK_FALSE;
            samplerInfo.compareOp = VK_COMPARE_OP_ALWAYS;
            samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
        }

        Vertex[] vertices;
        ushort[] indices;
        createOrientationCube(vertices, indices, 0.16f);

        auto img = loadImageToMemory(device, frameBuilder.commandPool, commandBuffer, extFormatImg, format);
        auto texture = device.create!Texture(img, samplerInfo);
        auto mesh = scene.texturedMeshFactory.create(scene.frameBuilder, vertices, indices, texture);

        textureBranch
            .addChild(Bone(mat: Vector3f(0.62f, 0.42f, 0).translationMatrix))
            .addChild(cast(DrawablePrimitive) mesh);
    }

    auto spheresBranch = primitTree.addChild(scene.sphereRenderer.pipelineCfg);
    spheresBranch.addChild(ShadowPipelineCfg(scene.sphereRenderer.shadowPipelineCfg));

    {
        const specs = [
            SphereSpec(Vector3f(0.3f, 1.0f, 0.4f), 20, 4, 0.018f, 0.040f, 0.045f, 0.26f),
            SphereSpec(Vector3f(0.4f, 0.6f, 1.0f), 8, 3, 0.030f, 0.090f, 0.060f, 0.46f),
            SphereSpec(
                Vector3f(1.0f, 0.5f, 0.4f), 5, 1, 0.080f, 0.140f, 0.000f, 0.66f,
                MaterialMode.normalsDebug,
            ),
        ];

        SphereInstance[] instances;
        SphereGroup[] groups;

        foreach(groupIndex, spec; specs)
        {
            groups ~= SphereGroup(Material(spec.color, spec.mode));

            foreach(row; 0 .. spec.rows)
            {
                foreach(col; 0 .. spec.cols)
                {
                    const x = (cast(float) col - cast(float)(spec.cols - 1) * 0.5f) * spec.xStep;
                    const y = spec.y0 + cast(float) row * spec.yStep;
                    instances ~= SphereInstance(Vector3f(x, y, 0), spec.radius, cast(uint) groupIndex);
                }
            }
        }

        scene.sphereRenderer.setInstances(instances, groups);
        spheresBranch.addChild(cast(DrawablePrimitive) scene.sphereRenderer);
    }

    auto cylinderPrimitives = new PrimitivesTree;
    tree.addChild(cylinderPrimitives);

    auto cylindersBranch = cylinderPrimitives.addChild(scene.cylinderRenderer.pipelineCfg);
    cylindersBranch.addChild(ShadowPipelineCfg(scene.cylinderRenderer.shadowPipelineCfg));

    {
        import std.math: PI, cos, sin;

        CylinderGroup[] groups = [
            CylinderGroup(
                Material(Vector3f(0.3f, 1.0f, 0.4f)),
                CylinderGroupFlags(CylinderGroupFlag.firstCap, CylinderGroupFlag.secondCap),
            ),
            CylinderGroup(
                Material(Vector3f(0.4f, 0.6f, 1.0f)),
                CylinderGroupFlags(CylinderGroupFlag.firstCap),
            ),
            CylinderGroup(
                Material(Vector3f(1.0f, 0.5f, 0.4f), MaterialMode.normalsDebug),
                CylinderGroupFlags(),
            ),
        ];

        CylinderInstance[] instances;

        const sampleCount = gltfFilesSearch(
            "demo/assets/gltf_samples/",
            benchMode ? benchSampleNames : null,
        ).length;
        const sectorAngle = 2.0f * PI / sampleCount;

        foreach(i; 0 .. sampleCount)
        {
            const angle = sectorAngle * cast(float) i;
            const cx = -0.2f * sin(angle);
            const cz = -0.2f * cos(angle);

            instances ~= CylinderInstance(
                Vector3f(cx, -0.58f, cz - 0.06f),
                Vector3f(cx, -0.58f, cz + 0.06f),
                0.010f,
                0,
            );
            instances ~= CylinderInstance(
                Vector3f(cx - 0.02f, -0.72f, cz - 0.02f),
                Vector3f(cx + 0.02f, -0.72f, cz + 0.02f),
                0.015f,
                1,
            );
            instances ~= CylinderInstance(
                Vector3f(cx, -0.92f, cz),
                Vector3f(cx, -0.80f, cz),
                0.020f,
                2,
            );
        }

        scene.cylinderRenderer.setInstances(instances, groups);
        cylindersBranch.addChild(cast(DrawablePrimitive) scene.cylinderRenderer);

        const axisA = instances[0];
        const axisB = instances[1];

        const dirA = axisA.p1 - axisA.p0;
        const dirB = axisB.p1 - axisB.p0;

        const extA0 = axisA.p0 - dirA * 0.5f;
        const extA1 = axisA.p1 + dirA * 0.5f;
        const extB0 = axisB.p0 - dirB * 0.5f;
        const extB1 = axisB.p1 + dirB * 0.5f;

        extendedLine = new LineRenderer(
            device,
            scene.pipelineFactory,
            scene.renderPass,
            scene.swapChain.imageExtent,
        );
        extendedLine.setLines([
            LineInstance(
                Vector4f(extA0.x, extA0.y, extA0.z, 2.0f),
                Vector4f(extA1.x, extA1.y, extA1.z, 1.0f),
                Vector4f(1.0f, 1.0f, 0.0f, 1.0f),
            ),
            LineInstance(
                Vector4f(extB0.x, extB0.y, extB0.z, 2.0f),
                Vector4f(extB1.x, extB1.y, extB1.z, 1.0f),
                Vector4f(1.0f, 0.5f, 0.0f, 1.0f),
            ),
        ]);

        auto extendedLineBranch = cylinderPrimitives.addChild(extendedLine.pipelineCfg);
        extendedLineBranch.addChild(cast(DrawablePrimitive) extendedLine);

        overlayLine = new LineRenderer(
            device,
            scene.pipelineFactory,
            scene.renderPass,
            scene.swapChain.imageExtent,
            true,
        );
        overlayLine.setLines([
            LineInstance(
                Vector4f(axisA.p0.x, axisA.p0.y, axisA.p0.z, 3.0f),
                Vector4f(axisA.p1.x, axisA.p1.y, axisA.p1.z, 1.0f),
                Vector4f(1.0f, 0.0f, 1.0f, 1.0f),
            ),
        ]);

        auto overlayBranch = overlayTree.addChild(overlayLine.pipelineCfg);
        overlayBranch.addChild(cast(DrawablePrimitive) overlayLine);
    }

    return tree;
}

auto texturedVertices =
    [
        Vertex(Vector3f(-0.5, -0.5, 0), Vector3f(1.0f, 0.0f, 0.0f), Vector2f(1, 0)),
        Vertex(Vector3f(0.5, -0.5, 0), Vector3f(0.0f, 1.0f, 0.0f), Vector2f(0, 0)),
        Vertex(Vector3f(0.5, 0.5, 0), Vector3f(0.0f, 0.0f, 1.0f), Vector2f(0, 1)),
        Vertex(Vector3f(-0.5, 0.5, 0), Vector3f(1.0f, 1.0f, 1.0f), Vector2f(1, 1)),
    ];

ushort[] texturedIndices =
    [
        2, 1, 0, 0, 3, 2,
    ];

auto createCubeVertices()
{
    auto red = Vector3f(1.0f, 0.0f, 0.0f);
    auto green = Vector3f(0.0f, 1.0f, 0.0f);
    auto blue = Vector3f(0.0f, 0.0f, 1.0f);

    auto vertices = [
        Vertex(Vector3f(-0.2, -0.2, -0.2), red),    // 0
        Vertex(Vector3f(-0.2, -0.2,  0.2), blue),   // 1
        Vertex(Vector3f( 0.2, -0.2, -0.2), green),  // 2
        Vertex(Vector3f( 0.2, -0.2,  0.2), green),  // 3
        Vertex(Vector3f( 0.2,  0.2, -0.2), red),    // 4
        Vertex(Vector3f( 0.2,  0.2,  0.2), green),  // 5
        Vertex(Vector3f(-0.2,  0.2,  0.2), red),    // 6
        Vertex(Vector3f(-0.2,  0.2, -0.2), green),  // 7
    ];

    ushort[] indices = [
        0, 1, 2, 3, 2, 1,   // 1
        2, 3, 4, 3, 5, 4,   // 2
        3, 6, 5, 1, 6, 3,   // 3
        4, 6, 7, 4, 5, 6,   // 4
        0, 6, 1, 0, 7, 6,   // 5
        0, 2, 7, 2, 4, 7,   // 6
    ];

    import std.typecons;
    return tuple(vertices, indices);
}

auto createLitCubeVertices()
{
    import dlib.math: cross;
    import std.typecons: tuple;

    const positions = [
        Vector3f(-0.2f, -0.2f, -0.2f), // 0
        Vector3f(-0.2f, -0.2f,  0.2f), // 1
        Vector3f( 0.2f, -0.2f, -0.2f), // 2
        Vector3f( 0.2f, -0.2f,  0.2f), // 3
        Vector3f( 0.2f,  0.2f, -0.2f), // 4
        Vector3f( 0.2f,  0.2f,  0.2f), // 5
        Vector3f(-0.2f,  0.2f,  0.2f), // 6
        Vector3f(-0.2f,  0.2f, -0.2f), // 7
    ];

    const ushort[] triangleIndices = [
        2, 1, 0, 1, 2, 3,
        2, 4, 3, 3, 4, 5,
        3, 5, 6, 1, 3, 6,
        4, 7, 6, 4, 6, 5,
        0, 1, 6, 0, 6, 7,
        0, 7, 2, 2, 7, 4,
    ];

    LitVertex[] vertices;
    ushort[] indices;

    foreach(t; 0 .. triangleIndices.length / 3)
    {
        const a = positions[triangleIndices[t * 3 + 0]];
        const b = positions[triangleIndices[t * 3 + 1]];
        const c = positions[triangleIndices[t * 3 + 2]];
        const normal = cross(b - a, c - a).normalized;

        const base = cast(ushort) vertices.length;

        foreach(p; [a, b, c])
            vertices ~= LitVertex(p, normal, Vector3f(1, 1, 1), Vector2f(0, 0));

        // The source triangles face outward; the draw order is the other way
        indices ~= [base, cast(ushort)(base + 2), cast(ushort)(base + 1)];
    }

    return tuple(vertices, indices);
}
