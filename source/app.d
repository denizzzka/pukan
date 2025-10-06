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

    debug auto dbg = vk.attachFlightRecorder();
    debug scope(exit) destroy(dbg);

    import pukan.vulkan.bindings: VkSurfaceKHR;
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

    import pukan.vulkan.bindings;

    VkDescriptorSetLayoutBinding[] descriptorSetLayoutBindings;
    {
        VkDescriptorSetLayoutBinding uboLayoutBinding = {
            binding: 0,
            descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            descriptorCount: 1,
            stageFlags: VK_SHADER_STAGE_VERTEX_BIT,
        };

        VkDescriptorSetLayoutBinding samplerLayoutBinding = {
            binding: 1,
            descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            descriptorCount: 1,
            stageFlags: VK_SHADER_STAGE_FRAGMENT_BIT,
        };

        descriptorSetLayoutBindings = [
            uboLayoutBinding,
            samplerLayoutBinding,
        ];
    }

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

    scope scene = new Scene(device, surface, descriptorSetLayoutBindings, &windowSizeChanged);
    scope(exit) destroy(scene);

    //FIXME: remove refs
    auto frameBuilder = &scene.frameBuilder;
    //~ ref pipelineInfoCreator = scene.pipelineInfoCreator;
    //~ ref graphicsPipelines = scene.graphicsPipelines;
    auto descriptorSets = &scene.descriptorSets;

    auto vertexBuffer = device.create!TransferBuffer(Vertex.sizeof * vertices.length, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
    scope(exit) destroy(vertexBuffer);

    auto indicesBuffer = device.create!TransferBuffer(ushort.sizeof * indices.length, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
    scope(exit) destroy(indicesBuffer);

    // Using any (first) buffer as buffer for initial loading
    auto initBuf = &scene.swapChain.frames[0].commandBuffer;

    // Copy vertices to mapped memory
    vertexBuffer.cpuBuf[0..$] = cast(void[]) vertices;
    indicesBuffer.cpuBuf[0..$] = cast(void[]) indices;

    vertexBuffer.uploadImmediate(frameBuilder.commandPool, *initBuf);
    indicesBuffer.uploadImmediate(frameBuilder.commandPool, *initBuf);

    scope texture = device.create!Texture(frameBuilder.commandPool, *initBuf);
    scope(exit) destroy(texture);

    VkWriteDescriptorSet[] descriptorWrites;

    {
        VkDescriptorBufferInfo bufferInfo = {
            buffer: frameBuilder.uniformBuffer.gpuBuffer,
            offset: 0,
            range: WorldTransformationUniformBuffer.sizeof,
        };

        VkDescriptorImageInfo imageInfo = {
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            imageView: texture.imageView,
            sampler: texture.sampler,
        };

        descriptorWrites = [
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: (*descriptorSets)[0 /*TODO: frame number*/],
                dstBinding: 0,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                descriptorCount: 1,
                pBufferInfo: &bufferInfo,
            ),
            VkWriteDescriptorSet(
                sType: VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet: (*descriptorSets)[0 /*TODO: frame number*/],
                dstBinding: 1,
                dstArrayElement: 0,
                descriptorType: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                pImageInfo: &imageInfo,
            )
        ];

        scene.descriptorPool.updateSets(descriptorWrites);
    }

    import pukan.exceptions;

    auto sw = StopWatch(AutoStart.yes);

    // Main loop
    while (!glfwWindowShouldClose(window))
    {
        glfwPollEvents();

        updateWorldTransformations(scene.frameBuilder, sw, scene.swapChain.imageExtent);

        scene.drawNextFrame((ref FrameBuilder fb, ref Frame frame) {
            auto cb = frame.commandBuffer;

            fb.uniformBuffer.recordUpload(cb);

            scene.renderPass.updateData(scene.renderPass.VariableData(
                scene.swapChain.imageExtent,
                frame.frameBuffer,
                vertexBuffer.gpuBuffer.buf,
                indicesBuffer.gpuBuffer.buf,
                *descriptorSets,
                scene.pipelineInfoCreator.pipelineLayout,
                scene.graphicsPipelines.pipelines[0]
            ));

            scene.renderPass.recordCommandBuffer(cb);
        });

        {
            import core.thread.osthread: Thread;
            import core.time;

            static size_t frameNum;
            static size_t fps;

            frameNum++;
            writeln("FPS: ", fps, ", frame: ", frameNum, ", currentFrameIdx: ", scene.swapChain.currentFrameIdx);

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

void updateWorldTransformations(V)(ref FrameBuilder frameBuilder, ref StopWatch sw, V imageExtent)
{
    const curr = sw.peek.total!"msecs" * 0.001;

    import dlib.math;

    auto rotation = rotationQuaternion(Vector3f(0, 0, 1), 90f.degtorad * curr);

    WorldTransformationUniformBuffer* wtb;
    assert(frameBuilder.uniformBuffer.cpuBuf.length == WorldTransformationUniformBuffer.sizeof);

    wtb = cast(WorldTransformationUniformBuffer*) frameBuilder.uniformBuffer.cpuBuf.ptr;
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
