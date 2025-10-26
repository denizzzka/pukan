import pukan;
import pukan.scene_tree;
import pukan.vulkan.bindings;
import glfw3.api;
import std.conv: to;
import std.datetime.stopwatch;
import std.exception;
import std.logger;
import std.stdio;
import std.string: toStringz;

enum fps = 60;
enum width = 640;
enum height = 640;

void main() {
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

    auto window = glfwCreateWindow(width, height, name.toStringz, null, null);
    enforce(window, "Cannot create a window");

    //~ glfwSetWindowUserPointer(demo.window, demo);
    //~ glfwSetWindowRefreshCallback(demo.window, &demo_refresh_callback);
    //~ glfwSetFramebufferSizeCallback(demo.window, &demo_resize_callback);
    //~ glfwSetKeyCallback(demo.window, &demo_key_callback);

    // Print needed extensions
    uint ext_count;
    const char** extensions = glfwGetRequiredInstanceExtensions(&ext_count);
    const(char*)[] extension_list = extensions[0 .. ext_count];

    version(none)
    {
        // Additional "heuristic": someday we'll refuse to give up on glfw

        extension_list ~= VK_KHR_SURFACE_EXTENSION_NAME.ptr;
        const(char)* surfaceName;

        version(Windows)
        {
            surfaceName = VK_KHR_WIN32_SURFACE_EXTENSION_NAME.ptr;
        }
        else //version(Posix)
        {
            import std.process: environment;

            const st = environment.get("XDG_SESSION_TYPE");

            if(st == "x11")
                surfaceName = VK_KHR_XCB_SURFACE_EXTENSION_NAME.ptr;
            else if(st == "wayland")
                surfaceName = VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME.ptr;
            else
                assert(false, "Surface not supported");
        }

        extension_list ~= surfaceName;
    }

    debug
    {
        writeln("Needed extensions:");
        foreach(i; extension_list)
            writeln(i.to!string);
    }

    auto vk = new Instance(name, makeApiVersion(1,2,3,4), extension_list);
    scope(exit) destroy(vk);

    //~ debug
    //~ {
        //~ writeln("Vulkan instance supported extensions:");
        //~ foreach(s; vk.extensions)
            //~ s.extensionName.to!string.writeln;
    //~ }

    //~ vk.printAllDevices();
    //~ vk.printAllAvailableLayers();

    auto physDevice = vk.findSuitablePhysicalDevice;
    //~ debug
    //~ {
        //~ writeln("");
        //~ writeln("Device supported extensions:");
        //~ foreach(s; physDevice.extensions)
            //~ s.extensionName.to!string.writeln;
    //~ }

    const(char*)[] dev_extension_list = [
        VK_KHR_SWAPCHAIN_EXTENSION_NAME.ptr,
        VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME.ptr,
    ];

    auto device =  physDevice.createLogicalDevice(dev_extension_list);
    scope(exit)
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

    import pukan.exceptions;

    auto sw = StopWatch(AutoStart.yes);

    writeln(); // empty line for FPS counter

    // Main loop
    while (!glfwWindowShouldClose(window))
    {
        glfwPollEvents();

        WorldTransformation wtb;
        updateWorldTransformations(wtb, sw, scene.swapChain.imageExtent, tree, cubeRotator);
        const transl = wtb.proj * wtb.view * wtb.model;

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

            scene.renderPass.recordCommandBuffer(cb, (buf){
                tree.drawingBufferFilling(buf, Matrix4x4f.identity);
            });
        });

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
            const curr = sw.peek;

            if(prevTime.split!"seconds" != curr.split!"seconds")
            {
                static size_t prevSecondFrameNum;
                fps = frameNum - prevSecondFrameNum;
                prevSecondFrameNum = frameNum;
            }

            auto remaining = frameDuration - (curr - prevTime);

            //~ if(!remaining.isNegative)
                //~ Thread.sleep(remaining);

            prevTime = curr;
        }
    }

    vkDeviceWaitIdle(device.device);
}

import dlib.math;

WorldTransformation calculateWTB(in VkExtent2D imageExtent, float currDeltaTime)
{
    auto rotation = rotationQuaternion(Vector3f(0, 0, 1), 90f.degtorad * currDeltaTime * 0.1);

    WorldTransformation wtb;

    wtb.model = rotation.toMatrix4x4;
    // View is turned inside out, so we don't need to correct winding order of the glTF mesh vertices
    wtb.view = lookAtMatrix(
        Vector3f(1, 1, 1), // camera position
        Vector3f(0, 0, 0), // point at which the camera is looking
        Vector3f(0, 0, -1), // upward direction in World coordinates
    );
    wtb.proj = perspectiveMatrix(
        45.0f /* FOV */,
        cast(float) imageExtent.width / imageExtent.height,
        0.1f /* zNear */, 10.0f /* zFar */
    );

    return wtb;
}

void updateWorldTransformations(out WorldTransformation wtb, ref StopWatch sw, in VkExtent2D imageExtent, SceneTree tree, Bone* cubeRotator)
{
    const curr = sw.peek.total!"msecs" * 0.001;

    wtb = calculateWTB(imageExtent, curr);

    auto cubeRotation = rotationQuaternion(Vector3f(0, 1, 0), 90f.degtorad * curr * 0.5);
    *cubeRotator = Bone(cubeRotation.toMatrix4x4);
}

auto createDemoTree(LogicalDevice device, Scene scene, FrameBuilder frameBuilder, scope VkCommandBuffer commandBuffer, out Bone* cubeRotator)
{
    auto tree = new SceneTree;

    auto primitTree = new PrimitivesTree;
    tree.addChild(primitTree);

    auto coloredBranch = primitTree.addChild(scene.coloredMeshFactory.graphicsPipelineCfg);

    {
        auto v = createCubeVertices;
        auto cube = scene.coloredMeshFactory.create(scene.frameBuilder, v[0], v[1]);

        auto n = coloredBranch.addChild(Bone());
        cubeRotator = n.payload.peek!Bone;

        //~ n.addChild(cast(DrawablePrimitive) cube);
    }

    //~ {
        //~ auto trans = Vector3f(0.2, 0.2, 0.2).scaleMatrix * Vector3f(1, 1, 0.3).translationMatrix;

        //~ auto gltfObj = scene.gltfFactory.create("demo/assets/gltf_samples/SimpleMeshes/glTF/SimpleMeshes.gltf");
        //~ tree.root
            //~ .addChild(Bone(mat: trans))
            //~ .addChild(gltfObj);
    //~ }

    //~ {
        //~ auto trans = Vector3f(0.2, 0.2, 0.2).scaleMatrix * Vector3f(1, 1, 2.3).translationMatrix;

        //~ auto gltfObj = scene.gltfFactory.create("demo/assets/gltf_samples/SimpleTexture/glTF/SimpleTexture.gltf");
        //~ tree.root
            //~ .addChild(Bone(mat: trans))
            //~ .addChild(gltfObj);
    //~ }

    {
        const max = Vector3f(21.870667, -40.59911, 114.58009);
        const min = Vector3f(21.469711, -40.855274, 114.2257);

        const center = (max + min)/2;

        const scale = 3;
        auto trans = (Vector3f(1, 1, 1) * scale).scaleMatrix * (-center).translationMatrix;

        //~ auto gltfObj = scene.gltfFactory.create("demo/assets/gltf_samples/Avocado/glTF-Binary/Avocado.glb");
        auto gltfObj = scene.gltfFactory.create("demo/assets/gltf_samples/Cat1/model.glb");
        //~ auto gltfObj = scene.gltfFactory.create("/home/denizzz/Dev/glTF-Sample-Assets/Models/CesiumMan/glTF-Binary/CesiumMan.glb");
        tree.root
            .addChild(Bone(mat: trans))
            .addChild(gltfObj);
    }

    //~ {
        //~ auto trans = Vector3f(0.2, 0.2, 0.2).scaleMatrix * Vector3f(-1, 1, 0.3).translationMatrix;

        //~ auto gltfObj = scene.gltfFactory.create("demo/assets/gltf_samples/AnimatedCube/glTF/AnimatedCube.gltf");
        //~ tree.root
            //~ .addChild(Bone(mat: trans))
            //~ .addChild(gltfObj);
    //~ }

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
            samplerInfo.maxAnisotropy = 16; //TODO: use vkGetPhysicalDeviceProperties (at least)
            samplerInfo.borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK;
            samplerInfo.unnormalizedCoordinates = VK_FALSE;
            samplerInfo.compareEnable = VK_FALSE;
            samplerInfo.compareOp = VK_COMPARE_OP_ALWAYS;
            samplerInfo.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
        }

        auto img = loadImageToMemory(device, frameBuilder.commandPool, commandBuffer, extFormatImg, format);
        auto texture = device.create!Texture(img, samplerInfo);
        auto mesh = scene.texturedMeshFactory.create(scene.frameBuilder, texturedVertices, texturedIndices, texture);

        //~ textureBranch.addChild(cast(DrawablePrimitive) mesh);
    }

    tree.uploadToGPUImmediate(device, frameBuilder.commandPool, commandBuffer);

    return tree;
}

auto texturedVertices =
    [
        Vertex(Vector3f(-0.5, -0.5, 0), Vector3f(1.0f, 0.0f, 0.0f), Vector2f(1, 0)),
        Vertex(Vector3f(0.5, -0.5, 0), Vector3f(0.0f, 1.0f, 0.0f), Vector2f(0, 0)),
        Vertex(Vector3f(0.5, 0.5, 0), Vector3f(0.0f, 0.0f, 1.0f), Vector2f(0, 1)),
        Vertex(Vector3f(-0.5, 0.5, 0), Vector3f(1.0f, 1.0f, 1.0f), Vector2f(1, 1)),

        Vertex(Vector3f(-0.5, -0.35, -0.5), Vector3f(1.0f, 0.0f, 0.0f), Vector2f(1, 0)),
        Vertex(Vector3f(0.5, -0.15, -0.5), Vector3f(0.0f, 1.0f, 0.0f), Vector2f(0, 0)),
        Vertex(Vector3f(0.5, 0.15, -0.5), Vector3f(0.0f, 0.0f, 1.0f), Vector2f(0, 1)),
        Vertex(Vector3f(-0.5, 0.35, -0.5), Vector3f(1.0f, 1.0f, 1.0f), Vector2f(1, 1)),
    ];

ushort[] texturedIndices =
    [
        0, 1, 2, 2, 3, 0,
        4, 5, 6, 6, 7, 4,
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
