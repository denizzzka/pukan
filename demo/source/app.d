import pukan;
import pukan.scene_tree;
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

alias appRequirements = Requirements!(SwapChain, GltfFactory, FrameBuilder);
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
    auto getoptResult = getopt(
        args,
        "stereo", "render side-by-side stereo", &stereo,
        "cross-eyed", "swap stereo halves for cross-eyed viewing", &crossEyed,
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
    scope tree = createDemoTree(device, scene, *frameBuilder, *initBuf, cubeRotator);
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
    while (!glfwWindowShouldClose(window))
    {
        glfwPollEvents();

        const curr = sw.peek.total!"msecs" * 0.001;

        WorldTransformation wtb;
        updateWorldTransformations(wtb, curr, scene.swapChain.imageExtent, tree, cubeRotator);
        const transl = wtb.proj * wtb.view * wtb.model;

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

WorldTransformation calculateWTB(in VkExtent2D imageExtent, float currDeltaTime)
{
    auto rotation = rotationQuaternion(Vector3f(0, 1, 0), 90f.degtorad * currDeltaTime * 0.1);

    WorldTransformation wtb;

    wtb.model = rotation.toMatrix4x4;
    // View is turned inside out, so we don't need to correct winding order of the glTF mesh vertices
    wtb.view = lookAtMatrix(
        Vector3f(0, -0.2, -0.8), // camera position
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
        Vector3f(0, -0.2, -0.8),
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

auto createDemoTree(LogicalDevice device, Scene scene, FrameBuilder frameBuilder, scope VkCommandBuffer commandBuffer, out Bone* cubeRotator)
{
    auto tree = new SceneTree;

    auto primitTree = new PrimitivesTree;

    {
        auto trans = Vector3f(0, 0, 1).translationMatrix;
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
