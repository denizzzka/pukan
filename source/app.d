import pukan;
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

    scope mesh = createDemoMesh();
    scope(exit) mesh.destroy;

    /// Vertices descriptor
    scope vd = mesh.uploadMeshToGPUImmediate(device, frameBuilder.commandPool, *initBuf);

    // Texture descriptor set:
    scope textureDstSet = scene.descriptorsSets[1][0 /*TODO: frame number*/];
    mesh.updateTextureDescriptorSet(device, *frameBuilder, frameBuilder.commandPool, *initBuf, scene.descriptorsPool[1], textureDstSet);

    import pukan.exceptions;

    auto sw = StopWatch(AutoStart.yes);

    auto renderData = DefaultRenderPass.VariableData(
        vertexBuffer: vd.vertexBuffer.gpuBuffer.buf,
        indexBuffer: vd.indicesBuffer.gpuBuffer.buf,
        indicesNum: vd.indicesNum,
        descriptorSets: scene.descriptorsSets[1],
        pipelineLayout: scene.pipelineInfoCreators[1].pipelineLayout,
        graphicsPipeline: scene.graphicsPipelines.pipelines[0],
    );

    writeln(); // empty line for FPS counter

    // Main loop
    while (!glfwWindowShouldClose(window))
    {
        glfwPollEvents();

        updateWorldTransformations(scene.frameBuilder.uniformBuffer, sw, scene.swapChain.imageExtent);

        scene.drawNextFrame((ref FrameBuilder fb, ref Frame frame) {
            auto cb = frame.commandBuffer;

            fb.uniformBuffer.recordUpload(cb);

            renderData.imageExtent = scene.swapChain.imageExtent,
            renderData.frameBuffer = frame.frameBuffer;
            scene.renderPass.updateData(renderData);
            scene.renderPass.recordCommandBuffer(cb);
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

void updateWorldTransformations(ref TransferBuffer uniformBuffer, ref StopWatch sw, in VkExtent2D imageExtent)
{
    const curr = sw.peek.total!"msecs" * 0.001;

    auto rotation = rotationQuaternion(Vector3f(0, 0, 1), 90f.degtorad * curr);

    WorldTransformationUniformBuffer* wtb;
    assert(uniformBuffer.cpuBuf.length == WorldTransformationUniformBuffer.sizeof);

    wtb = cast(WorldTransformationUniformBuffer*) uniformBuffer.cpuBuf.ptr;
    wtb.model = rotation.toMatrix4x4;
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
}

/// Displaying data
auto createDemoMesh()
{
    auto r = new Mesh;
    r.vertices = [
        Vertex(Vector3f(-0.5, -0.5, 0), Vector3f(1.0f, 0.0f, 0.0f), Vector2f(1, 0)),
        Vertex(Vector3f(0.5, -0.5, 0), Vector3f(0.0f, 1.0f, 0.0f), Vector2f(0, 0)),
        Vertex(Vector3f(0.5, 0.5, 0), Vector3f(0.0f, 0.0f, 1.0f), Vector2f(0, 1)),
        Vertex(Vector3f(-0.5, 0.5, 0), Vector3f(1.0f, 1.0f, 1.0f), Vector2f(1, 1)),

        Vertex(Vector3f(-0.5, -0.35, -0.5), Vector3f(1.0f, 0.0f, 0.0f), Vector2f(1, 0)),
        Vertex(Vector3f(0.5, -0.15, -0.5), Vector3f(0.0f, 1.0f, 0.0f), Vector2f(0, 0)),
        Vertex(Vector3f(0.5, 0.15, -0.5), Vector3f(0.0f, 0.0f, 1.0f), Vector2f(0, 1)),
        Vertex(Vector3f(-0.5, 0.35, -0.5), Vector3f(1.0f, 1.0f, 1.0f), Vector2f(1, 1)),
    ];
    r.indices = [
        0, 1, 2, 2, 3, 0,
        4, 5, 6, 6, 7, 4,
    ];

    return r;
}
