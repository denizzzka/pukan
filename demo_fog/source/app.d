import pukan;
import pukan.graphics.g3d.primitives_tree.cylinder: CylinderRenderer;
import pukan.graphics.g3d.primitives_tree.sphere: SphereRenderer;
import pukan.graphics.g3d.primitives_tree.mesh: LitMesh, LitVertex;
import pukan.vulkan.bindings;
import pukan.vulkan.renderpass: DrawPhase;
import pukan.vulkan.requirements: DeviceCheck, DeviceContext, DeviceFilter, Requirements, extensionNames, OptionalRequirementsFor, RequirementsFor;
import pukan.vulkan.textures: Texture;
import core.time: Duration, MonoTime;
import dlib.math: degtorad, Matrix4x4f, scaleMatrix, Vector2f, Vector3f, Vector4f, translationMatrix;
import glfw3.api;
import std.exception: enforce;
import std.getopt: defaultGetoptPrinter, getopt;
import std.meta: AliasSeq;
import std.string: toStringz;
import std.stdio;

enum width = 1280;
enum height = 720;
enum cameraNear = 0.1f;
enum cameraFar = 200.0f;

alias appRequirements = Requirements!(SwapChain, GltfFactory, FrameBuilder, SphereRenderer, CylinderRenderer, CullFrame);

debug alias DebugEntities = AliasSeq!(LayerSettings);
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

Scene scene;
FlyCamera camera;
CameraControls controls;
bool fogOn = true;
bool heightFogOn = true;
bool shadowsOn = true;
double fogDensity = 0.25;

void main(string[] args)
{
    version(linux)
    version(DigitalMars)
    {
        import etc.linux.memoryerror;
        registerMemoryAssertHandler();
    }

    uint frames;
    bool offscreen;
    bool noShadows;
    bool noHeightFog;
    bool noVolumetric;
    string screenshotPath;
    string look = "rich";
    double maxFps = 60;
    double density = double.nan;
    double sunIntensity = 8.0;
    double ibl = 0.2;

    auto getoptResult = getopt(
        args,
        "frames", "exit after N frames (0 = run forever)", &frames,
        "offscreen", "render without a window, for screenshots", &offscreen,
        "no-shadows", "do not cast shadows", &noShadows,
        "no-height-fog", "leave out the ground fog layer", &noHeightFog,
        "no-volumetric", "leave out the volumetric fog", &noVolumetric,
        "look", "mist or rich (default: rich)", &look,
        "screenshot", "save the last frame to this PNG", &screenshotPath,
        "max-fps", "cap frames per second, 0 = only vsync", &maxFps,
        "density", "fog extinction per metre", &density,
        "sun", "sun intensity", &sunIntensity,
        "ibl", "image based lighting intensity", &ibl,
    );

    if(getoptResult.helpWanted)
    {
        defaultGetoptPrinter("pukan3D volumetric fog demo", getoptResult.options);
        return;
    }

    shadowsOn = !noShadows;
    heightFogOn = !noHeightFog;

    if(noVolumetric)
        fogOn = false;
    enforce(look == "mist" || look == "rich", "unknown look: " ~ look ~ " (mist, rich)");

    if(offscreen && frames == 0)
        frames = 1;

    enforce(glfwInit());
    scope(exit) glfwTerminate();
    enforce(glfwVulkanSupported());

    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);

    GLFWwindow* window;
    if(!offscreen)
    {
        window = glfwCreateWindow(width, height, "pukan3D volumetric fog".toStringz, null, null);
        enforce(window, "Cannot create a window");
        glfwSetKeyCallback(window, &onKey);
        glfwSetScrollCallback(window, &onScroll);
    }

    const(char)*[] instanceExtensions = offscreen ? null : glfwExtraExtensions!appEntities();
    auto vk = Instance.createWith!appEntities("pukan3D volumetric fog", 1, instanceExtensions);
    scope(exit) destroy(vk);

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

        enum queueFlags = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;

        foreach(i, family; ctx.queueFamilies)
        {
            if((family.queueFlags & queueFlags) != queueFlags)
                continue;

            if(surface == VkSurfaceKHR.init)
                return true;

            VkBool32 supported;
            vkGetPhysicalDeviceSurfaceSupportKHR(ctx.device, cast(uint) i, surface, &supported).vkCheck;

            if(supported != VK_TRUE)
            {
                reason = "queue family " ~ i.to!string ~ " does not support presentation";
                continue;
            }

            if(chooseSurfaceFormat(ctx.device, surface, reason).format != VK_FORMAT_UNDEFINED)
                return true;
        }

        return false;
    }

    DeviceFilter filter;
    filter.checks ~= DeviceCheck("surface", &surfaceCheck);

    auto selected = vk.findSuitablePhysicalDevice!appRequirements(filter);
    auto physDevice = selected.device();

    VkSurfaceFormatKHR surfaceFormat;
    if(!offscreen)
    {
        string reason;
        surfaceFormat = physDevice.chooseSurfaceFormat(surface, reason);
        enforce(surfaceFormat.format != VK_FORMAT_UNDEFINED, reason);
    }

    auto device = selected.createLogicalDevice!(Texture)();
    scope(exit)
    {
        import core.memory: GC;

        GC.collect();
        destroy(device);
    }

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

    if(offscreen)
        scene = new Scene(device, VkExtent2D(width, height), VK_FORMAT_R8G8B8A8_SRGB,
            "fog demo", DepthFormat.float32Stencil);
    else
        scene = new Scene(
            device,
            surface,
            &windowSizeChanged,
            surfaceFormat,
            "fog demo",
            DepthFormat.float32Stencil,
            VK_PRESENT_MODE_FIFO_KHR,
        );
    scope(exit) destroy(scene);

    scene.frameRateLimit = maxFps;
    scene.sunShadow.enabled = shadowsOn;
    scene.localShadow.enabled = false;
    scene.sunShadow.fit(Boxf(Vector3f(-14.0f, -2.0f, -14.0f), Vector3f(14.0f, 8.0f, 14.0f)));

    camera = FlyCamera.lookingAt(Vector3f(2.2f, 1.3f, -8.5f), Vector3f(-2.6f, 2.6f, 0.0f), scene.up);
    camera.fov = 55.0f;
    camera.speed = 4.0f;

    scene.setSun(Vector3f(-0.7f, 0.35f, 0.62f), Vector3f(1.0f, 0.94f, 0.82f), cast(float) sunIntensity);
    scene.iblIntensity = cast(float) ibl;
    scene.background.setSky(
        Vector3f(0.04f, 0.06f, 0.12f),
        Vector3f(0.16f, 0.19f, 0.28f),
        Vector3f(0.06f, 0.06f, 0.07f),
        Vector3f(0.02f, 0.02f, 0.03f),
        1.0f,
    );
    scene.ambientLight = Vector4f(0.38f, 0.43f, 0.58f, 0.10f);

    scene.volumetricFog.enabled = fogOn;
    scene.volumetricFog.density = cast(float) fogDensity;
    scene.volumetricFog.albedo = Vector3f(1.0f, 0.96f, 0.88f);
    scene.volumetricFog.anisotropy = 0.6f;
    scene.volumetricFog.length = 45.0f;

    scene.heightFog.enabled = heightFogOn;
    scene.heightFog.density = 0.05f;
    scene.heightFog.height = 0.0f;
    scene.heightFog.falloff = 0.7f;
    scene.heightFog.color = Vector3f(0.30f, 0.36f, 0.46f);

    // A dense cloud between the columns, hanging under the lantern
    scene.fogVolumes ~= FogVolume(
        FogVolumeShape.ellipsoid,
        Vector3f(-1.0f, 1.6f, 1.0f),
        Vector3f(2.4f, 1.6f, 2.4f),
        2.2f,
        Vector3f(0.45f, 0.46f, 0.48f),
        Vector3f(0.0f, 0.0f, 0.0f),
        0.0f,
        0.6f,
    );
    scene.fogVolumes[$ - 1].noise = 1.0f;
    scene.fogVolumes[$ - 1].noiseScale = 0.9f;

    scene.addSpotLight(
        Vector3f(-2.4f, 4.2f, 1.8f),
        Vector3f(0.45f, -1.0f, -0.25f),
        Vector3f(1.0f, 0.72f, 0.40f) * 22.0f,
        14.0f,
        20f.degtorad,
        34f.degtorad,
    );

    if(look == "rich")
    {
        // A warm sun and a dense cool fog, so the saturated sides of both show
        scene.setSun(Vector3f(-0.7f, 0.30f, 0.62f), Vector3f(1.0f, 0.66f, 0.36f), 3.5f);
        scene.background.setSky(
            Vector3f(0.012f, 0.03f, 0.09f),
            Vector3f(0.10f, 0.21f, 0.33f),
            Vector3f(0.05f, 0.06f, 0.07f),
            Vector3f(0.015f, 0.015f, 0.02f),
            1.0f,
        );
        scene.ambientLight = Vector4f(0.20f, 0.35f, 0.60f, 0.25f);

        fogDensity = 0.02;
        scene.volumetricFog.density = cast(float) fogDensity;
        scene.volumetricFog.albedo = Vector3f(1.0f, 0.80f, 0.55f);
        scene.volumetricFog.anisotropy = 0.5f;

        scene.heightFog.density = 0.02f;
        scene.heightFog.falloff = 0.6f;
        scene.heightFog.color = Vector3f(0.08f, 0.16f, 0.28f);

        // The dense cool fog dims what the cloud scatters, so it darkens too
        scene.fogVolumes[$ - 1].density = 3.2f;
        scene.fogVolumes[$ - 1].albedo = Vector3f(0.30f, 0.31f, 0.34f);
    }

    // An explicit density wins over the preset's choice
    import std.math: isNaN;

    if(!density.isNaN)
        fogDensity = density;

    LitMesh[] meshes;
    auto instances = buildScene(meshes);
    scope(exit) foreach(mesh; meshes) destroy(mesh);

    writeln("camera: WASD move, right mouse look, middle mouse pan, wheel zoom, Q/E roll");
    writeln("fog: G toggle, [ ] density, F ground layer, T shadows");

    auto clock = MonoTime.currTime;
    auto previous = clock;
    uint frameCount;
    const captureFrame = frames ? frames : 1;

    bool running = true;
    while(running && (frames == 0 || frameCount < frames))
    {
        if(!offscreen)
            glfwPollEvents();

        if(offscreen)
        {
            const now = MonoTime.currTime;
            clock = now;
        }

        const now = offscreen ? clock : MonoTime.currTime;
        float dt = cast(float) (now - previous).total!"nsecs" / 1_000_000_000.0f;
        previous = now;

        if(dt > 0.1f)
            dt = 0.1f;

        if(!offscreen)
        {
            bool pressed(int key) nothrow @nogc => glfwGetKey(window, key) == GLFW_PRESS;

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

            const looking = glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS;
            const panning = glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_MIDDLE) == GLFW_PRESS;

            double cursorX;
            double cursorY;
            glfwGetCursorPos(window, &cursorX, &cursorY);
            controls.cursorMoved(cursorX, cursorY, looking, panning);

            controls.update(camera, state, dt);
        }

        frameCount++;

        if(screenshotPath.length && frameCount == captureFrame)
            scene.captureFrame(screenshotPath);

        scene.sunShadow.enabled = shadowsOn;
        scene.volumetricFog.enabled = fogOn;
        scene.volumetricFog.density = cast(float) fogDensity;
        scene.heightFog.enabled = heightFogOn;

        scene.volumetricFog.animationTime = cast(float) frameCount / 60.0f;

        scene.drawNextFrame((ref FrameBuilder fb, ref Frame frame, RenderTarget target) {

            DefaultRenderPass.VariableData renderData;
            renderData.common.imageExtent = target.extent;
            renderData.common.frameBuffer = frame.frameBuffer;
            scene.renderPass.updateData(renderData);

            const aspect = target.extent.height ? cast(float) target.extent.width / target.extent.height : 1.0f;

            WorldTransformation wtb;
            wtb.model = Matrix4x4f.identity;
            wtb.view = camera.view;
            wtb.proj = vulkanPerspectiveMatrix(camera.fov, aspect, cameraNear, cameraFar);

            scene.updateFrameUniforms(frame, 0, wtb);

            scene.recordCommandBuffer(
                frame,
                (buf, view, layout, phase) {
                    foreach(instance; instances)
                        instance.mesh.drawingBufferFilling(
                            buf,
                            scene.litMeshFactory.graphicsPipelineCfg,
                            wtb.proj * wtb.view * wtb.model * instance.transform,
                            frame.frameSets[0].descriptorSet,
                        );
                },
                null,
                (buf, cascade) {
                    foreach(instance; instances)
                        if(instance.castShadow)
                            instance.mesh.drawingShadow(
                                buf,
                                scene.litMeshFactory.shadowGraphicsPipelineCfg,
                                scene.sunShadow.cascades.viewProj[cascade] * wtb.model * instance.transform,
                            );
                },
                (buf, tile) {
                    foreach(instance; instances)
                        if(instance.castShadow)
                            instance.mesh.drawingShadow(
                                buf,
                                scene.litMeshFactory.shadowGraphicsPipelineCfg,
                                scene.localShadow.viewProj[tile] * wtb.model * instance.transform,
                            );
                },
            );
        });

        if(!offscreen && glfwWindowShouldClose(window))
            running = false;
    }

    if(screenshotPath.length)
        writeln("screenshot saved to ", scene.lastScreenshotPath);
}

/// Ground, a colonnade of pillars and a few crates, all sharing three meshes
MeshInstance[] buildScene(out LitMesh[] meshes)
{
    auto box = createLitBoxVertices();

    auto ground = scene.litMeshFactory.create(scene.frameBuilder, box[0], box[1]);
    ground.setMaterial(fogDemoMaterial(Vector3f(0.10f, 0.10f, 0.10f), 0.9f));
    ground.applyMaterial(scene.device);

    auto stone = scene.litMeshFactory.create(scene.frameBuilder, box[0], box[1]);
    stone.setMaterial(fogDemoMaterial(Vector3f(0.16f, 0.15f, 0.13f), 0.75f));
    stone.applyMaterial(scene.device);

    auto wood = scene.litMeshFactory.create(scene.frameBuilder, box[0], box[1]);
    wood.setMaterial(fogDemoMaterial(Vector3f(0.14f, 0.09f, 0.05f), 0.85f));
    wood.applyMaterial(scene.device);

    meshes = [ground, stone, wood];

    auto pool = scene.device.createCommandPool();
    auto buffers = pool.allocateBuffers(1);

    foreach(mesh; meshes)
        mesh.uploadToGPUImmediate(scene.device, pool, buffers[0]);

    pool.freeBuffers(buffers);
    destroy(pool);

    MeshInstance[] instances;

    void add(LitMesh mesh, Vector3f center, Vector3f halfExtents, bool castShadow = true)
    {
        // The shared mesh spans -0.2 to 0.2, so the scale reaches the wanted half extents
        const scale = halfExtents / 0.2f;

        instances ~= MeshInstance(
            mesh,
            translationMatrix(center) * scale.scaleMatrix,
            castShadow,
        );
    }

    add(ground, Vector3f(0.0f, -0.1f, 0.0f), Vector3f(10.0f, 0.1f, 10.0f), false);

    foreach(i; 0 .. 5)
    {
        const x = -4.0f + i * 2.0f;

        add(stone, Vector3f(x, 2.0f, -2.0f), Vector3f(0.32f, 2.0f, 0.32f));
        add(stone, Vector3f(x, 2.0f, 4.0f), Vector3f(0.32f, 2.0f, 0.32f));
    }

    foreach(i; 0 .. 4)
        add(
            wood,
            Vector3f(-2.0f + i * 1.3f, 0.4f, 0.6f),
            Vector3f(0.4f, 0.4f, 0.4f),
        );

    return instances;
}

/// One instance of a shared mesh
struct MeshInstance
{
    LitMesh mesh;
    Matrix4x4f transform;
    /// Off for a receiver like the ground, whose own depth would shadow it
    bool castShadow = true;
}

Material fogDemoMaterial(Vector3f color, float roughness)
{
    auto material = Material(color, MaterialMode.pbr);
    material.metallicRoughness.y = roughness;
    return material;
}

/// A cube spanning -0.2 to 0.2, wound the way the mesh pipeline expects
auto createLitBoxVertices()
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
        indices ~= [base, cast(ushort) (base + 2), cast(ushort) (base + 1)];
    }

    return tuple(vertices, indices);
}

extern(C) void onScroll(GLFWwindow*, double, double yoffset) nothrow @nogc
{
    controls.scroll(cast(float) yoffset);
}

extern(C) void onKey(GLFWwindow* window, int key, int, int action, int) nothrow @nogc
{
    if(action != GLFW_PRESS)
        return;

    switch(key)
    {
        case GLFW_KEY_ESCAPE:
            glfwSetWindowShouldClose(window, GLFW_TRUE);
            break;

        case GLFW_KEY_G:
            fogOn = !fogOn;
            break;

        case GLFW_KEY_F:
            heightFogOn = !heightFogOn;
            break;

        case GLFW_KEY_T:
            shadowsOn = !shadowsOn;
            break;

        case GLFW_KEY_LEFT_BRACKET:
            fogDensity = fogDensity > 0.005 ? fogDensity - 0.005 : 0.001;
            break;

        case GLFW_KEY_RIGHT_BRACKET:
            fogDensity += 0.005;
            break;

        default:
            break;
    }
}
