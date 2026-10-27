import pukan;
import pukan.scene_tree;
import pukan.primitives_tree.cylinder: CylinderGroup, CylinderGroupFlag, CylinderGroupFlags, CylinderInstance, CylinderRenderer;
import pukan.primitives_tree.sphere: SphereGroup, SphereGroupFlag, SphereGroupFlags, SphereInstance, SphereRenderer;
import pukan.vulkan.bindings;
import pukan.vulkan.core: FlightRecorder, LayerSettings;
import pukan.vulkan.textures: Texture;
import glfw3.api;
import std.datetime.stopwatch;
import std.exception;
import std.logger;
import std.meta: AliasSeq;
import std.stdio;
import std.string: toStringz;

alias appRequirements = Requirements!(SwapChain, GltfFactory, FrameBuilder, SphereRenderer, CylinderRenderer);
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
    uint frames;
    auto getoptResult = getopt(
        args,
        "stereo", "render side-by-side stereo", &stereo,
        "cross-eyed", "swap stereo halves for cross-eyed viewing", &crossEyed,
        "frames", "exit after N frames (0 = run forever)", &frames,
    );

    if(getoptResult.helpWanted)
    {
        defaultGetoptPrinter("pukan3D demo", getoptResult.options);
        return;
    }

    if(crossEyed)
        stereo = true;

    version(linux)
    version(DigitalMars)
    {
        import etc.linux.memoryerror;
        registerMemoryAssertHandler();
    }

    immutable name = "D/pukan3D/GLFW project";

    enforce(glfwInit());
    scope(exit) glfwTerminate();

    enforce(glfwVulkanSupported());

    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    //~ glfwWindowHint(GLFW_RESIZABLE, GLFW_FALSE);

    const windowWidth = stereo ? width * 2 : width;
    auto window = glfwCreateWindow(windowWidth, height, name.toStringz, null, null);
    enforce(window, "Cannot create a window");
    glfwSetScrollCallback(window, &onScroll);
    glfwSetMouseButtonCallback(window, &onMouseButton);
    glfwSetCursorPosCallback(window, &onCursorPos);
    glfwGetCursorPos(window, &cursorX, &cursorY);

    //~ glfwSetWindowUserPointer(demo.window, demo);
    //~ glfwSetWindowRefreshCallback(demo.window, &demo_refresh_callback);
    //~ glfwSetFramebufferSizeCallback(demo.window, &demo_resize_callback);
    //~ glfwSetKeyCallback(demo.window, &demo_key_callback);

    auto vk = Instance.createWith!appEntities(name, 1, glfwExtraExtensions!appEntities());
    scope(exit) destroy(vk);

    //~ debug
    //~ {
        //~ writeln("Vulkan instance supported extensions:");
        //~ foreach(s; vk.extensions)
            //~ s.extensionName.to!string.writeln;
    //~ }

    //~ vk.printAllDevices();
    //~ vk.printAllAvailableLayers();

    auto selected = vk.findSuitablePhysicalDevice!appRequirements();
    auto physDevice = selected.device();
    //~ debug
    //~ {
        //~ writeln("");
        //~ writeln("Device supported extensions:");
        //~ foreach(s; physDevice.extensions)
            //~ s.extensionName.to!string.writeln;
    //~ }

    auto device = selected.createLogicalDevice!(Texture)();
    scope(success)
    {
        import core.memory: GC;

        GC.collect();
        destroy(device);
    }

    debug auto dbg = vk.attachFlightRecorder(device);
    debug scope(exit) destroy(dbg);

    static import glfw3.internal;

    VkSurfaceKHR surface;
    glfwCreateWindowSurface(
        vk.instance,
        window,
        cast(glfw3.internal.VkAllocationCallbacks*) vk.allocator,
        cast(ulong*) &surface
    );

    //~ vk.printSurfaceFormats(vk.devices[vk.deviceIdx], surface);
    //~ vk.printPresentModes(vk.devices[vk.deviceIdx], surface);

    void windowSizeChanged()
    {
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

    scope scene = new Scene(device, surface, &windowSizeChanged);
    scope(exit) destroy(scene);

    //TODO: remove
    auto frameBuilder = &scene.frameBuilder;

    // Using any (of first frame, for example) buffer as buffer for initial loading
    auto initBuf = &scene.swapChain.frames[0].commandBuffer();

    Bone* cubeRotator;
    LineRenderer extendedLine;
    LineRenderer overlayLine;
    scope tree = createDemoTree(device, scene, *frameBuilder, *initBuf, cubeRotator, extendedLine, overlayLine);
    scope(exit) tree.destroy;

    GlTF[] arenaGltfs;
    {
        auto trans = Vector3f(0, 0, 0).translationMatrix;
        auto arenaNode = tree.addChild(Bone(mat: trans));
        arenaGltfs = createArena(scene, arenaNode);
    }

    tree.uploadToGPUImmediate(device, frameBuilder.commandPool, *initBuf);

    import pukan.exceptions;

    auto sw = StopWatch(AutoStart.yes);

    writeln(); // empty line for FPS counter

    // Main loop
    uint frameCount;
    while (!glfwWindowShouldClose(window) && (frames == 0 || frameCount < frames))
    {
        frameCount++;

        frameTime = glfwGetTime();
        glfwPollEvents();

        const curr = sw.peek.total!"msecs" * 0.001;

        static float prevCurr = 0.0f;
        const dt = curr - prevCurr;
        prevCurr = curr;

        if(!sceneDragging && frameTime - lastInteractionTime > autoResumeDelay)
            sceneYaw += autoRotationSpeed * dt;

        WorldTransformation wtb;
        updateWorldTransformations(wtb, curr, scene.swapChain.imageExtent, tree, cubeRotator);
        const transl = wtb.proj * wtb.view * wtb.model;

        const sphereViewModel = wtb.view * wtb.model * Vector3f(0, 0, sceneDepth).translationMatrix;
        const aspect = cast(float) scene.swapChain.imageExtent.width / scene.swapChain.imageExtent.height;

        scene.sphereRenderer.setCamera(
            sphereViewModel,
            cameraFovY,
            aspect,
            scene.swapChain.imageExtent.height,
            cameraNear,
            cameraFar,
        );
        const cylinderViewModel = wtb.view * wtb.model;

        scene.cylinderRenderer.setCamera(
            cylinderViewModel,
            cameraFovY,
            aspect,
            scene.swapChain.imageExtent.height,
            cameraNear,
            cameraFar,
        );

        extendedLine.setViewport(scene.swapChain.imageExtent);
        overlayLine.setViewport(scene.swapChain.imageExtent);

        if(!stereo)
            tree.root.payload = Bone(transl);

        scene.drawNextFrame((ref FrameBuilder fb, ref Frame frame) {

            {
                DefaultRenderPass.VariableData renderData;
                renderData.common.imageExtent = scene.swapChain.imageExtent;
                renderData.common.frameBuffer = frame.frameBuffer;
                scene.renderPass.updateData(renderData);
            }

            auto cb = frame.commandBuffer;

            scene.sphereRenderer.prepare(cb);
            scene.cylinderRenderer.prepare(cb);

            tree.forEachDrawablePayload((d) => d.refreshBuffers(cb));

            if(stereo)
            {
                scene.recordStereoCommandBuffer(cb, (buf, eye, eyeExtent) {
                    const view = crossEyed ? 1 - eye : eye;
                    auto stereoWtb = calculateStereoWTB(eyeExtent, curr);
                    tree.root.payload = Bone(stereoWtb[view].proj * stereoWtb[view].view * stereoWtb[view].model);
                    tree.drawingBufferFilling(buf, Matrix4x4f.identity);
                });
            }
            else
            {
                scene.recordCommandBuffer(cb, (buf){
                    tree.drawingBufferFilling(buf, Matrix4x4f.identity);
                });
            }
        });

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

        {
            import core.thread.osthread: Thread;
            import core.time;

            static size_t frameNum;
            static size_t fps;

            frameNum++;
            write("\rFPS: ", fps, ", frame: ", frameNum, ", currentFrameIdx: ", scene.swapChain.currentFrameIdx);

            enum targetFPS = 80;
            enum frameDuration = dur!"nsecs"(1_000_000_000 / targetFPS);
            static Duration prevTime;
            const now = sw.peek;

            if(prevTime.split!"seconds" != now.split!"seconds")
            {
                static size_t prevSecondFrameNum;
                fps = frameNum - prevSecondFrameNum;
                prevSecondFrameNum = frameNum;
            }

            auto remaining = frameDuration - (now - prevTime);

            //~ if(!remaining.isNegative)
                //~ Thread.sleep(remaining);

            prevTime = now;
        }
    }

    vkDeviceWaitIdle(device.device);
}

import dlib.math;

enum cameraFovY = 45.0f;
enum cameraNear = 0.1f;
enum cameraFar = 10.0f;
enum stereoEyeSeparation = 0.06f;
enum initialCameraDistance = 2.2f;
enum minCameraDistance = 0.6f;
enum maxCameraDistance = 2.5f;
enum sceneDepth = 1.0f;

float cameraDistance = initialCameraDistance;

extern(C) void onScroll(GLFWwindow*, double, double yoffset) nothrow @nogc
{
    auto distance = cameraDistance - cast(float) yoffset * 0.1f;

    if(distance < minCameraDistance)
        distance = minCameraDistance;
    if(distance > maxCameraDistance)
        distance = maxCameraDistance;

    cameraDistance = distance;
}

enum autoRotationSpeed = 90f.degtorad * 0.1f;
enum autoResumeDelay = 10.0;
enum manualRotationSensitivity = 0.006f;
enum maxScenePitch = 80f.degtorad;

double frameTime;
double lastInteractionTime = -1e9;
double cursorX;
double cursorY;
bool sceneDragging;
float sceneYaw = 0.0f;
float scenePitch = 0.0f;

extern(C) void onMouseButton(GLFWwindow*, int button, int action, int) nothrow @nogc
{
    if(button != GLFW_MOUSE_BUTTON_LEFT)
        return;

    if(action == GLFW_PRESS)
    {
        sceneDragging = true;
        lastInteractionTime = frameTime;
    }
    else if(action == GLFW_RELEASE)
    {
        sceneDragging = false;
        lastInteractionTime = frameTime;
    }
}

extern(C) void onCursorPos(GLFWwindow*, double xpos, double ypos) nothrow @nogc
{
    const dx = xpos - cursorX;
    const dy = ypos - cursorY;
    cursorX = xpos;
    cursorY = ypos;

    if(!sceneDragging)
        return;

    sceneYaw += cast(float) dx * manualRotationSensitivity;
    scenePitch += cast(float) dy * manualRotationSensitivity;

    if(scenePitch > maxScenePitch)
        scenePitch = maxScenePitch;
    if(scenePitch < -maxScenePitch)
        scenePitch = -maxScenePitch;

    lastInteractionTime = frameTime;
}

WorldTransformation calculateWTB(in VkExtent2D imageExtent, float currDeltaTime)
{
    WorldTransformation wtb;

    wtb.model = rotationMatrix!float(Axis.y, sceneYaw) * rotationMatrix!float(Axis.x, scenePitch);
    // View is turned inside out, so we don't need to correct winding order of the glTF mesh vertices
    wtb.view = lookAtMatrix(
        Vector3f(0, -0.2f, -cameraDistance), // camera position
        Vector3f(0, 0, 0), // point at which the camera is looking
        Vector3f(0, 1, 0), // downward direction (upward if OpenGL) in World coordinates.
    );
    wtb.proj = perspectiveMatrix(
        cameraFovY,
        cast(float) imageExtent.width / imageExtent.height,
        cameraNear, cameraFar,
    );

    return wtb;
}

WorldTransformation[2] calculateStereoWTB(in VkExtent2D eyeExtent, float currDeltaTime)
{
    auto base = calculateWTB(eyeExtent, currDeltaTime);
    const views = makeStereoViews(
        Vector3f(0, -0.2f, -cameraDistance),
        Vector3f(0, 0, 0),
        Vector3f(0, 1, 0),
        cameraFovY,
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

void updateWorldTransformations(out WorldTransformation wtb, float curr, in VkExtent2D imageExtent, SceneTree tree, Bone* cubeRotator)
{
    wtb = calculateWTB(imageExtent, curr);

    auto cubeRotation = rotationQuaternion(Vector3f(0, 1, 0), 90f.degtorad * curr * 0.5);
    *cubeRotator = Bone(cubeRotation.toMatrix4x4);
}

private string[] gltfFilesSearch(string dir)
{
    import std.file;

    auto samples = dirEntries(dir, "*", SpanMode.shallow);
    string[] found;
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

GlTF[] createArena(T)(Scene scene, ref T node)
{
    import std.math;

    const found = gltfFilesSearch("demo/assets/gltf_samples/");
    const sectorAngle = PI*2 / found.length;

    const radius = 0.2;
    const startPlace = Vector3f(0, 0, -radius);

    GlTF[] loaded;
    foreach(i, filename; found)
    {
        auto obj = scene.gltfFactory.create(filename);
        const aabb = obj.calcAABB;
        const size = aabb.max - aabb.min;
        const center = aabb.min + size/2;
        const scale = 1.0 / size.length * 0.1;

        auto trans = Matrix4x4f.identity;

        trans *= rotationMatrix!float(Axis.y, sectorAngle * i);
        trans *= startPlace.translationMatrix;

        trans *= (Vector3f(1, 1, 1) * scale).scaleMatrix;
        trans *= center.translationMatrix;

        node
            .addChild(Bone(mat: trans))
            .addChild(obj);

        loaded ~= obj;
    }

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
    SphereGroupFlags flags;
}

auto createDemoTree(
    LogicalDevice device,
    Scene scene,
    FrameBuilder frameBuilder,
    scope VkCommandBuffer commandBuffer,
    out Bone* cubeRotator,
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

    {
        auto v = createCubeVertices;
        auto cube = scene.coloredMeshFactory.create(scene.frameBuilder, v[0], v[1]);

        auto n = coloredBranch.addChild(Bone());
        cubeRotator = n.payload.peek!Bone;

        n.addChild(cast(DrawablePrimitive) cube);
    }

    auto textureBranch = primitTree.addChild(scene.texturedMeshFactory.graphicsPipelineCfg);

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

    auto spheresBranch = primitTree.addChild(scene.sphereRenderer.pipelineCfg);

    {
        const specs = [
            SphereSpec(Vector3f(0.3f, 1.0f, 0.4f), 20, 4, 0.018f, 0.040f, 0.045f, 0.26f),
            SphereSpec(Vector3f(0.4f, 0.6f, 1.0f), 8, 3, 0.030f, 0.090f, 0.060f, 0.46f),
            SphereSpec(
                Vector3f(1.0f, 0.5f, 0.4f), 5, 1, 0.080f, 0.140f, 0.000f, 0.66f,
                SphereGroupFlags(SphereGroupFlag.normals),
            ),
        ];

        SphereInstance[] instances;
        SphereGroup[] groups;

        foreach(groupIndex, spec; specs)
        {
            groups ~= SphereGroup(spec.color, spec.flags);

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

    {
        import std.math: PI, cos, sin;

        CylinderGroup[] groups = [
            CylinderGroup(
                Vector3f(0.3f, 1.0f, 0.4f),
                CylinderGroupFlags(CylinderGroupFlag.firstCap, CylinderGroupFlag.secondCap),
            ),
            CylinderGroup(
                Vector3f(0.4f, 0.6f, 1.0f),
                CylinderGroupFlags(CylinderGroupFlag.firstCap),
            ),
            CylinderGroup(
                Vector3f(1.0f, 0.5f, 0.4f),
                CylinderGroupFlags(CylinderGroupFlag.normals),
            ),
        ];

        CylinderInstance[] instances;

        const sampleCount = gltfFilesSearch("demo/assets/gltf_samples/").length;
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
        2, 1, 0, 1, 2, 3,   // 1
        2, 4, 3, 3, 4, 5,   // 2
        3, 5, 6, 1, 3, 6,   // 3
        4, 7, 6, 4, 6, 5,   // 4
        0, 1, 6, 0, 6 ,7,   // 5
        0, 7, 2, 2, 7, 4,   // 6
    ];

    import std.typecons;
    return tuple(vertices, indices);
}
