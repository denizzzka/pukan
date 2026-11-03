import dlib.math: Axis, Matrix4x4f, Vector3f, Vector4f, rotationMatrix;
import pukan;
import pukan.graphics.g3d.axes: axisVector;
import pukan.graphics.common.misc: Boxf, hasBounds, trsMatrix;
import pukan.gltf.motion_sampler: MotionSampler;
import pukan.motion_matching.database: Clip, Database, invalidSample;
import pukan.motion_matching.history: PoseHistory;
import pukan.motion_matching.matching: Matching;
import pukan.motion_matching.search: currentVelocity;
import pukan.motion_matching.query: Query, buildQuery;
import pukan.motion_matching.schema: LocomotionBones, Schema;
import pukan.motion_matching.trajectory: Trajectory;
import pukan.motion_matching.transform: Transform, wrapAngle;
import pukan.mover.component: MoverComponent;
import pukan.mover.quake: QuakeBody, QuakeCommand, QuakeMovementConfig;
import pukan.graphics.g3d.pbr.pipelines: plainShading;
import pukan.physics.simulation: Simulation;
import pukan.physics.world: CollisionWorld, ShapeCastHit;
import pukan.graphics.g3d.primitives_tree.lines: LineInstance, LineRenderer;
import pukan.vulkan.bindings;
import pukan.vulkan.core: FlightRecorder, LayerSettings;
import glfw3.api;
import std.algorithm: max, min, remove;
import std.math: PI, abs, atan2, cos, sin, sqrt;
import std.exception: enforce;
import std.getopt: defaultGetoptPrinter, getopt;
import std.meta: AliasSeq;
import std.stdio: writeln;
import std.string: toStringz;

alias appRequirements = Requirements!(SwapChain, GodotFactory, FrameBuilder, CullFrame);
debug alias DebugEntities = AliasSeq!(FlightRecorder, LayerSettings);
else alias DebugEntities = AliasSeq!();

alias appEntities = AliasSeq!(DebugEntities, WindowSurface);

/// Share of the run speed that makes the search pick a walk instead of a run
private enum walkSpeedFactor = 0.2f;

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

/// First surface below the top of the level, in the middle of the scene: what a level
/// without a spawn marker offers
Vector3f levelSpawn(CollisionWorld world, in Boxf bounds, in Vector3f up)
{
    const extent = (bounds.max - bounds.min).length;
    const center = (bounds.min + bounds.max) * 0.5f;
    const hit = world.raycast(center + up * (extent + 1), -up, 2 * extent + 2);

    return hit.hit ? hit.point + up * 0.01f : center;
}

/// Lifts a spawn point that sits inside the geometry until the capsule no longer overlaps
/// it: a marker under the terrain would otherwise trap the character for good
Vector3f freeSpawn(CollisionWorld world, Vector3f feet, in Vector3f up, float radius, float height)
{
    ShapeCastHit overlap;

    if(!world.overlapCapsule(feet + up * radius, feet + up * (height - radius), radius, uint.max, 0.001f, overlap))
        return feet;

    foreach(i; 0 .. 200)
    {
        feet += up * 0.25f;

        if(!world.overlapCapsule(feet + up * radius, feet + up * (height - radius), radius, uint.max, 0.001f, overlap))
            return feet;
    }

    return feet;
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

/// Turns `current` towards `wanted` by at most `step` radians, the short way round.
private float turnTowards(float current, float wanted, float step)
{
    const float turn = wrapAngle(wanted - current);

    return current + (turn > step ? step : (turn < -step ? -step : turn));
}

LineInstance[] capsuleLines(
    Vector3f feet,
    QuakeBody body,
    Vector4f color,
    float width,
)
{
    LineInstance[] lines;
    const radius = body.radius;
    const height = body.height;
    const up = body.up.axisVector;
    const xAxis = Vector3f(1, 0, 0);
    const zAxis = Vector3f(0, 0, 1);
    const bottom = feet + up * radius;
    const top = feet + up * (height - radius);

    void add(Vector3f a, Vector3f b)
    {
        lines ~= LineInstance(
            Vector4f(a.x, a.y, a.z, width),
            Vector4f(b.x, b.y, b.z, 0),
            color,
        );
    }

    foreach(i; 0 .. 16)
    {
        const angle = 2.0f * PI * i / 16.0f;
        const radial = xAxis * cos(angle) + zAxis * sin(angle);
        add(bottom + radial * radius, top + radial * radius);
    }

    foreach(i; 0 .. 32)
    {
        const a0 = 2.0f * PI * i / 32.0f;
        const a1 = 2.0f * PI * (i + 1) / 32.0f;
        const r0 = xAxis * cos(a0) + zAxis * sin(a0);
        const r1 = xAxis * cos(a1) + zAxis * sin(a1);
        add(bottom + r0 * radius, bottom + r1 * radius);
        add(top + r0 * radius, top + r1 * radius);
    }

    foreach(i; 0 .. 8)
    {
        const angle = PI * i / 8.0f;
        const radial = xAxis * cos(angle) + zAxis * sin(angle);
        Vector3f previousBottom = bottom + radial * radius;
        Vector3f previousTop = top + radial * radius;

        foreach(j; 1 .. 12)
        {
            const t = PI * j / 12.0f;
            const bottomPoint = bottom + radial * (cos(t) * radius) - up * (sin(t) * radius);
            const topPoint = top + radial * (cos(t) * radius) + up * (sin(t) * radius);
            add(previousBottom, bottomPoint);
            add(previousTop, topPoint);
            previousBottom = bottomPoint;
            previousTop = topPoint;
        }
    }

    return lines;
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
    bool characterMode = true;
    bool thirdPerson = true;
    bool noCharacter;
    bool firstPerson;
    string spawnOption;
    bool walkForward;
    bool fixedStep;
    bool noclip;
    bool noSpringArm;
    bool debugCapsule;
    string modelOption;
    float physicsHz = 60.0f;
    float moveSpeedOption;
    float modelScaleOption;
    float fovOption = cameraFov;
    float nearOption = cameraNear;
    float farOption = cameraFar;
    float speedOption = cameraSpeed;
    float cellRange = 128.0f;
    bool noCells;
    bool noGpuCull;
    string pickOrigin;
    string pickDirection;

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
        "character", "walk a Quake-style capsule through the level, the default", &characterMode,
        "no-character", "fly the free camera instead of walking", &noCharacter,
        "first-person", "start in the character's eyes instead of behind it", &firstPerson,
        "spawn", "character spawn position, x,y,z", &spawnOption,
        "walk", "hold forward, for headless movement tests", &walkForward,
        "fixed-step", "advance one physics tick per frame", &fixedStep,
        "noclip", "ignore collision in character mode", &noclip,
        "cell-range", "stream cells within this distance in metres", &cellRange,
        "no-cells", "load every cell at start instead of streaming them", &noCells,
        "no-gpu-cull", "cull the parts of a cell on the CPU instead of the GPU", &noGpuCull,
        "pick", "report what a ray from this point hits, x,y,z", &pickOrigin,
        "pick-dir", "ray direction for --pick, x,y,z", &pickDirection,
        "no-spring-arm", "keep the third-person camera at a fixed distance", &noSpringArm,
        "debug-capsule", "draw the character collision capsule", &debugCapsule,
        "model", "character model path; defaults to CesiumMan", &modelOption,
        "third-person", "draw the character from behind", &thirdPerson,
        "physics-hz", "fixed character tick rate", &physicsHz,
        "move-speed", "character speed in units per second; defaults to the Quake maximum", &moveSpeedOption,
        "model-scale", "scale the character model by this factor; 0 fits it to 1.8 units tall", &modelScaleOption,
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

    if(noCharacter)
        characterMode = false;

    if(firstPerson)
        thirdPerson = false;

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
            vk.instance.vk,
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
        scene = new Scene(device, VkExtent2D(width, height), VK_FORMAT_R8G8B8A8_SRGB, "demo_godot");
    else
        scene = new Scene(device, surface, &windowSizeChanged, surfaceFormat, "demo_godot");
    scope(exit) destroy(scene);

    scene.sunShadow.enabled = !noShadows;
    scene.sunShadow.cache = true;
    scene.godotFactory.preloadShadows = !noShadows;

    if(scenePath.length == 0 && packPath.length == 0)
        scenePath = characterMode
            ? "demo_godot/godot_samples/platformer/stage/stage.tscn"
            : "demo_godot/godot_samples/truck_town/town_view.tscn";

    auto godotScene = packPath.length
        ? scene.godotFactory.createPacked(packPath, scenePath)
        : scene.godotFactory.create(scenePath);
    scope(exit) destroy(godotScene);

    GlTF characterModel;
    Vector3f characterModelOffset;

    MotionSampler motionSampler;
    Database motionDatabase;
    Matching matching;
    Trajectory trajectory;
    PoseHistory poseHistory;
    Query motionQuery;
    size_t[] motionModelClips;
    size_t motionClip;
    float motionTime;
    bool motionReady;
    /// Horizontal speed of the pose playing and how fast it plays: together they move the capsule
    float motionSpeed = 0;
    float motionRate = 1;
    /// Horizontal root velocity of the playing pose, in the model's own axes
    Vector3f motionVelocity = Vector3f(0, 0, 0);
    /// Whether the set has sideways and backward clips, so the body keeps facing the view
    bool hasStrafe;
    /// Turn from the engine's forward to the way the mesh is authored; moves the mesh only,
    /// since the pose velocities are already measured from the root bone
    float modelFacingOffset = 0;
    /// Bounds of the skeleton at the idle pose, in the model's own space
    Vector3f idleLowest;
    Vector3f idleHighest;
    bool idleMeasured;
    float characterModelScale = 1.0f;
    /// Body measurements taken from the model, zero until they are known
    float capsuleRadius = 0;
    float capsuleHeight = 0;

    if(characterMode)
    {
        import std.file: exists;

        const modelPath = modelOption.length
            ? modelOption
            : "demo/assets/motion/UAL1_Standard_RM.glb";

        if(exists(modelPath))
            characterModel = scene.gltfFactory.create(modelPath);

        if(characterModel)
        {
            try
            {
                // TODO: a bone binding will pick the names of any rig; until then this flag
                // stands in for it and only recognises the RPG one
                bool rpgAsset;
                // TODO: measure the facing from the rig instead of recognising the asset, so
                // that any model works
                /// The mesh is authored facing -Z, as Godot does, so it needs a half turn
                bool godotForward;

                foreach(ref node; characterModel.asset.nodes)
                    if(node.payload.name == "Motion")
                    {
                        rpgAsset = true;
                        godotForward = true;
                    }

                auto schema = rpgAsset
                    ? Schema.locomotion(0.01f, LocomotionBones("Motion", "B_Pelvis", "B_Head",
                        "B_L_Hand", "B_R_Hand", "B_L_Foot", "B_R_Foot"))
                    : Schema.locomotion;

                motionSampler = new MotionSampler(characterModel.asset, schema);

                // The capsule follows the clip, so the clip must not move the mesh a second time
                characterModel.setRootMotionNode(motionSampler.rootNodeIndex);

                const modelClips = motionSampler.clips();

                foreach(i, ref clip; modelClips)
                {
                    if(rpgAsset && (clip.name == "UnarmedIdle" || clip.name == "UnarmedWalkInjured"
                        || clip.name == "UnarmedRunForward"
                        || clip.name == "UnarmedSprint" || clip.name == "UnarmedStrafeLeft"
                        || clip.name == "UnarmedStrafeRight" || clip.name == "UnarmedStrafeForward"
                        || clip.name == "UnarmedStrafeBackward"
                        || clip.name == "UnarmedStrafeForwardLeft"
                        || clip.name == "UnarmedStrafeForwardRight"
                        || clip.name == "UnarmedStrafeBackwardLeft"))
                        motionModelClips ~= i;

                    if(!rpgAsset && (clip.name == "Idle_Loop" || clip.name == "Walk_Loop"
                        || clip.name == "Jog_Fwd_Loop" || clip.name == "Sprint_Loop"))
                        motionModelClips ~= i;
                }

                hasStrafe = rpgAsset;

                if(godotForward)
                    modelFacingOffset = PI;

                if(motionModelClips.length > 0)
                {
                    size_t idleClip = motionModelClips[0];

                    foreach(i, ref clip; modelClips)
                        if(rpgAsset ? clip.name == "UnarmedIdle" : clip.name == "Idle_Loop")
                            idleClip = i;

                    motionSampler.boneBounds(idleClip, 0, idleLowest, idleHighest);
                    idleMeasured = true;

                    Clip[] locomotionClips;

                    foreach(i; motionModelClips)
                        locomotionClips ~= modelClips[i];


                    motionDatabase.build(schema, scene.up, locomotionClips,
                        (size_t clip, float time) => motionSampler.sample(motionModelClips[clip], time));

                    motionReady = true;
                    motionClip = 0;
                    motionTime = 0;
                    characterModel.playAnimation(motionModelClips[0], 0);

                    writeln("motion matching: ", locomotionClips.length, " clips ",
                        motionDatabase.samples.length, " poses ",
                        schema.dimensions, " channels");
                }
            }
            catch(Exception e)
                writeln("motion matching off: ", e.msg);
        }
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

    // A flat grid like Unreal's runtime hash: one tall layer of square cells
    const levelBounds = godotScene.calcAABB;

    if(hasBounds(levelBounds))
        scene.cellGrid = CellGrid(
            Vector3f(64, levelBounds.max.y - levelBounds.min.y + 2, 64),
            Vector3f(0, levelBounds.min.y, 0),
        );

    scope levelIndex = new CellIndex!DrawItem(scene.cellGrid);
    placeDrawable(levelIndex, godotScene, Matrix4x4f.identity);
    const levelCells = levelIndex.cells;

    if(characterModel)
    {
        characterModel.uploadToGPUImmediate(device, scene.frameBuilder.commandPool, *initialBuffer);

        const bounds = characterModel.calcAABB();

        if(bounds.min.y == bounds.min.y && bounds.max.y > bounds.min.y)
        {
            // A skinned mesh follows its skeleton, not its own node, so the taller of the two
            // is what the character is scaled by
            float height = bounds.max.y - bounds.min.y;

            if(idleMeasured)
                height = max(height, idleHighest.y - idleLowest.y);

            // Even scaling only: a bind pose with the arms out is wider than the capsule, and
            // squeezing the width to fit it flattens the whole body
            characterModelScale = modelScaleOption > 0 ? modelScaleOption : 1.8f / height;

            characterModelOffset = Vector3f(0, -bounds.min.y * characterModelScale, 0);
            capsuleHeight = height * characterModelScale;
        }

        if(idleMeasured)
        {
            // The capsule follows the body, not the other way round: the bind pose has the
            // arms out, so the body is measured on the idle pose, where they hang down
            const float width = idleHighest.x - idleLowest.x;
            const float depth = idleHighest.z - idleLowest.z;

            capsuleRadius = (max(width, depth) / 2 + 0.04f) * characterModelScale;
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

    // The platformer stage runs along X, so that is where a walk without steering goes
    if(characterMode && !eyeOption.length && !targetOption.length)
    {
        eye = Vector3f(0, 3, 0);
        target = Vector3f(1, 3, 0);
    }

    FlyCamera camera;
    float nearPlane = nearOption;
    float farPlane = farOption;

    if(useSceneCamera && godotScene.hasCamera)
    {
        camera = FlyCamera.fromView(godotScene.camera.view, scene.up);
        camera.fov = godotScene.camera.fov;
        nearPlane = godotScene.camera.nearPlane;
        farPlane = godotScene.camera.farPlane;
    }
    else
    {
        camera = FlyCamera.lookingAt(eye, target, scene.up);
        camera.fov = fovOption;
    }

    camera.speed = speedOption;

    QuakeBody characterBody;
    characterBody.up = scene.up;
    QuakeMovementConfig characterConfig;

    if(capsuleHeight > 0 && capsuleRadius > 0)
    {
        characterBody.height = capsuleHeight;
        characterBody.radius = capsuleRadius;
        characterBody.eyeHeight = capsuleHeight - 0.2f;

        writeln("capsule radius ", characterBody.radius, " height ", characterBody.height,
            " scale ", characterModelScale);
    }

    if(moveSpeedOption > 0)
        characterConfig.maxSpeed = moveSpeedOption;
    MoverComponent mover;
    QuakeCommand characterCommand;
    characterCommand.wishDir = Vector3f(0, 0, 0);
    characterCommand.wishSpeed = 0.0f;
    characterCommand.jump = false;

    Simulation simulation;

    if(characterMode)
    {
        Vector3f spawn;
        bool spawnKnown = false;

        if(spawnOption.length)
        {
            spawn = parseVector(spawnOption);
            spawnKnown = true;
        }
        else
            spawnKnown = godotScene.spawnPosition(spawn);

        if(!spawnKnown)
            spawn = levelSpawn(collisionWorld, godotScene.calcAABB, scene.up.axisVector);

        spawn = freeSpawn(collisionWorld, spawn, scene.up.axisVector, characterBody.radius, characterBody.height);

        writeln("spawn ", spawn.x, ", ", spawn.y, ", ", spawn.z);

        mover = new MoverComponent(collisionWorld, characterBody, characterConfig);
        mover.setNoclip(noclip);
        mover.teleport(spawn);

        simulation = new Simulation(collisionWorld);
        simulation.setTickRate(physicsHz);
    }
    scope(exit) if(simulation) destroy(simulation);

    LineRenderer debugCapsuleLines;

    if(debugCapsule)
        debugCapsuleLines = new LineRenderer(
            device, scene.pipelineFactory, scene.renderPass,
            scene.swapChain.imageExtent, false, 4096, true);

    scope(exit) if(debugCapsuleLines) destroy(debugCapsuleLines);

    if(!offscreen)
        writeln(characterMode
            ? "character: WASD move, right mouse look, middle mouse orbit, Space jump, V third person"
            : "camera: WASD move, right mouse look, middle mouse pan, wheel zoom, Q/E roll, R reset roll, H look axis (horizontal)");

    const captureFrame = screenshotFrame ? screenshotFrame : (frames ? frames : 1);
    // Cells stream around the camera unless every cell is asked for at once
    auto residency = new Residency(scene.cellGrid);
    residency.framesInFlight = cast(uint) scene.swapChain.frames.length;

    const bool streaming = !noCells;

    StreamingSource cameraSource(float range, CellState state)
    {
        StreamingSource source;
        source.position = camera.position;
        source.range = range;
        source.state = state;

        return source;
    }

    if(streaming)
    {
        residency.update([
            cameraSource(cellRange, CellState.active),
            cameraSource(cellRange * 1.5f, CellState.loaded),
        ], 0);

        scope initialCells = residency.active() ~ residency.take(size_t.max);

        // Holds are per cell, the same way releases will be
        foreach(cell; initialCells)
            holdCells(levelIndex, [cell]);

        scene.frameBuilder.commandPool.recordOneTimeAndSubmit(*initialBuffer, (buf) {
            uploadCells(levelIndex, buf, initialCells, size_t.max);
        });
    }
    else
    {
        foreach(cell; levelCells)
            holdCells(levelIndex, [cell]);

        scene.frameBuilder.commandPool.recordOneTimeAndSubmit(*initialBuffer, (buf) {
            uploadCells(levelIndex, buf, levelCells, size_t.max);
        });
    }

    // Taken cells upload a byte budget at a time, so a heavy cell never stalls a frame
    enum cellUploadBudget = 1 << 20;
    enum maxLoadingCells = 16;
    CellCoord[] loadingCells;

    if(pickOrigin.length)
    {
        const origin = parseVector(pickOrigin);
        const direction = pickDirection.length ? parseVector(pickDirection) : Vector3f(0, 0, -1);

        DrawItem item;
        float distance;

        if(levelIndex.raycast(levelCells, origin, direction, float.max, item, distance))
        {
            string partName;

            if(item.part != wholePart)
                partName = (cast(PartDrawable) item.drawable).partName(item.part);
            else if(auto level = cast(GodotScene) item.drawable)
                partName = level.name;
            else if(auto gltf = cast(GlTF) item.drawable)
                partName = gltf.possibleName;

            writeln("pick ", partName, " at ", distance, ": ", origin + direction * distance);
        }
        else
            writeln("pick nothing");
    }

    uint frameIndex;
    import core.time: MonoTime;
    const start = MonoTime.currTime;
    double lastTime = offscreen ? 0.0 : glfwGetTime();
    double characterCursorX = 0.0;
    double characterCursorY = 0.0;
    bool characterCursorKnown;
    /// Whether the middle button is taking the camera around the body
    bool orbitHeld;
    float characterMaxHeight = -float.infinity;
    float characterYaw = 0.0f;
    /// Direction the character faces, in the `Transform` convention; third person turns it
    /// towards the movement, first person keeps it on the camera
    float characterFacing = atan2(camera.forward.x, camera.forward.z);
    float thirdPersonDistance = 6.0f;
    bool thirdPersonKeyWasDown;
    bool characterVisible = true;
    Vector3f characterRenderPosition;

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

                const bool looking =
                    glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS;
                // The middle button walks the camera around the body, which is how it is
                // inspected from every side
                const bool orbiting = thirdPerson
                    && glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_MIDDLE) == GLFW_PRESS;

                // Without sideways clips the body follows its movement rather than the view, so
                // only a strafing rig has to be held still for the orbit
                orbitHeld = orbiting && hasStrafe;

                // A held button owns the cursor, so the look does not stop at a border
                if((looking || orbiting) != cursorCaptured)
                {
                    cursorCaptured = looking || orbiting;
                    characterCursorKnown = false;

                    if(cursorCaptured)
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

                double cursorX;
                double cursorY;
                glfwGetCursorPos(window, &cursorX, &cursorY);

                if(characterCursorKnown)
                {
                    const dx = cast(float) (cursorX - characterCursorX);
                    const dy = cast(float) (cursorY - characterCursorY);

                    if(looking || orbiting)
                        camera.look(dx, dy);
                }

                characterCursorX = cursorX;
                characterCursorY = cursorY;
                characterCursorKnown = true;

                const bool thirdPersonKey = pressed(GLFW_KEY_V);

                if(thirdPersonKey && !thirdPersonKeyWasDown)
                {
                    thirdPerson = !thirdPerson;
                    thirdPersonDistance = 6.0f;
                }

                thirdPersonKeyWasDown = thirdPersonKey;

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

                const bool walk = pressed(GLFW_KEY_LEFT_SHIFT)
                    || pressed(GLFW_KEY_RIGHT_SHIFT);

                characterCommand.wishDir = wish;
                characterCommand.wishSpeed = wish.length > 1e-6f
                    ? (walk ? characterConfig.maxSpeed * walkSpeedFactor
                        : characterConfig.maxSpeed)
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

            // Block on slow streaming: the camera's cell arrives before the body moves
            bool waitingForCell;

            if(streaming)
                foreach(cell; loadingCells)
                    if(cell == scene.cellGrid.of(camera.position))
                    {
                        waitingForCell = true;
                        break;
                    }

            if(!waitingForCell)
            simulation.step(dt, (tickDt) {
                mover.step(characterCommand, tickDt);

                if(motionReady)
                {
                    // The clip owns the motion, so the feet cannot slide; the input then reaches
                    // the search only as the wanted velocity of the predicted trajectory
                    // The pose velocity is measured from the root bone, so it already points the
                    // way the body does; only the facing turns it into world space
                    const float scale = motionRate * characterModelScale;
                    const float c = cos(characterFacing);
                    const float s = sin(characterFacing);

                    mover.state.velocity = Vector3f(
                        (motionVelocity.x * c + motionVelocity.z * s) * scale,
                        mover.state.velocity.y,
                        (-motionVelocity.x * s + motionVelocity.z * c) * scale,
                    );
                }
                characterMaxHeight = characterMaxHeight > mover.state.position.y
                    ? characterMaxHeight
                    : mover.state.position.y;
            });

            const alpha = simulation.interpolationAlpha();

            // Third person draws the simulated position, so mesh and capsule agree
            characterRenderPosition = thirdPerson
                ? mover.state.position
                : mover.renderPosition(alpha);

            const eyePosition = thirdPerson
                ? mover.state.position + characterBody.up.axisVector * characterBody.eyeHeight
                : mover.eyePosition(alpha);

            Vector3f flatForward = camera.forward;
            flatForward.y = 0;

            // The middle button takes the camera around the body, so the body keeps its facing
            if(!orbitHeld)
            {
                if(thirdPerson && !hasStrafe)
                {
                    Vector3f wish = characterCommand.wishDir;
                    wish.y = 0;

                    if(wish.length > 1e-4f)
                        // A limited turn keeps the feet plausible while strafing or backing up
                        characterFacing = turnTowards(characterFacing,
                            atan2(wish.x, wish.z), 10.0f * dt);
                }
                else if(flatForward.length > 1e-4f)
                    characterFacing = turnTowards(characterFacing,
                        atan2(flatForward.x, flatForward.z), 10.0f * dt);
            }

            characterYaw = -(characterFacing + modelFacingOffset);

            if(motionReady)
            {
                // The query describes the capsule as it moves; the search then picks the pose
                // that fits it, and the chosen clip is played from the chosen time
                // The wanted velocity only shapes the prediction, so a change of intent settles
                // over a few searches; clips at more speeds or a heavier trajectory sharpen it
                Vector3f wish = characterCommand.wishDir;
                wish.y = 0;

                const float wantedYaw = wish.length > 1e-4f
                    ? atan2(wish.x, wish.z)
                    : characterFacing;

                // The database speaks model units, the body moves in world units
                trajectory.push(dt, Transform(mover.state.position, characterFacing),
                    mover.state.velocity / characterModelScale,
                    characterCommand.wishDir * characterCommand.wishSpeed / characterModelScale,
                    wantedYaw);

                const playing = motionSampler.sample(motionModelClips[motionClip], motionTime);
                poseHistory.push(dt, playing.bones);

                buildQuery(motionQuery, motionDatabase.schema, scene.up, trajectory, poseHistory);

                matching.currentSample = motionDatabase.sampleIndex(motionClip, motionTime);

                const decision = matching.step(motionDatabase, motionQuery, dt);

                if(decision.sample != invalidSample)
                {
                    const picked = motionDatabase.samples[decision.sample];

                    motionClip = picked.clip;
                    motionTime = picked.time;

                    characterModel.blendToAnimation(motionModelClips[motionClip], motionTime, 0.15f);
                }
                else
                {
                    const float advance = dt * decision.playRate;

                    motionTime += advance;
                    characterModel.advanceAnimation(advance);
                }

                const float clipLength = motionDatabase.clips[motionClip].duration;

                if(clipLength > 0)
                    motionTime %= clipLength;

                const Vector3f poseVelocity = currentVelocity(motionDatabase.schema,
                    motionDatabase.vectorOf(matching.currentSample));

                motionVelocity = Vector3f(poseVelocity.x, 0, poseVelocity.z);
                motionSpeed = sqrt(poseVelocity.x * poseVelocity.x + poseVelocity.z * poseVelocity.z);
                motionRate = decision.playRate;

                if(frameIndex % 60 == 0)
                    writeln("motion: ", motionDatabase.clips[motionClip].name,
                        " t=", motionTime, " rate=", decision.playRate,
                        " pose speed=", motionSpeed, " capsule speed=",
                        sqrt(mover.state.velocity.x * mover.state.velocity.x
                            + mover.state.velocity.z * mover.state.velocity.z));
            }

            if(thirdPerson)
            {
                const back = -camera.forward;
                const desired = 6.0f;
                float targetDistance = desired;

                if(!noSpringArm)
                {
                    const hit = collisionWorld.raycast(eyePosition, back, desired,
                        characterBody.mask);

                    if(hit.hit)
                        targetDistance = hit.t > 0.1f ? hit.t - 0.1f : 0.1f;
                }

                if(targetDistance < thirdPersonDistance)
                    thirdPersonDistance = targetDistance;
                else
                {
                    const blend = dt * 6.0f < 1.0f ? dt * 6.0f : 1.0f;
                    thirdPersonDistance += (targetDistance - thirdPersonDistance) * blend;
                }

                characterVisible = thirdPersonDistance > 0.75f;
                camera.position = eyePosition + back * thirdPersonDistance;
            }
            else
                camera.position = eyePosition;
        }
        else if(!offscreen)
            updateCamera(camera, window, dt);

        Matrix4x4f characterTransform = Matrix4x4f.identity();

        if(characterMode && characterModel)
            characterTransform = trsMatrix(
                characterRenderPosition + characterModelOffset,
                rotationMatrix!float(Axis.y, characterYaw),
                Vector3f(characterModelScale, characterModelScale, characterModelScale),
            );

        if(debugCapsuleLines && characterMode)
        {
            debugCapsuleLines.setViewport(scene.swapChain.imageExtent);
            debugCapsuleLines.setLines(capsuleLines(characterRenderPosition, characterBody,
                Vector4f(0.2f, 0.85f, 1.0f, 0.45f), 1.5f));
        }

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

            if(streaming)
            {
                residency.update([
                    cameraSource(cellRange, CellState.active),
                    cameraSource(cellRange * 1.5f, CellState.loaded),
                ], frameIndex);

                const freeSlots = loadingCells.length >= maxLoadingCells
                    ? 0
                    : maxLoadingCells - loadingCells.length;

                if(freeSlots)
                    foreach(cell; residency.take(freeSlots))
                    {
                        holdCells(levelIndex, [cell]);
                        loadingCells ~= cell;
                    }

                size_t budget = cellUploadBudget;
                CellCoord[] stillLoading;

                foreach(cell; loadingCells)
                {
                    if(budget == 0)
                    {
                        stillLoading ~= cell;
                        continue;
                    }

                    const used = uploadCells(levelIndex, frame.commandBuffer(), [cell], budget);
                    budget -= min(budget, used);

                    // Zero bytes means the cell has everything it needs
                    if(used > 0)
                        stillLoading ~= cell;
                }

                loadingCells = stillLoading;

                foreach(cell; residency.release(frameIndex))
                {
                    releaseCells(levelIndex, [cell]);
                    loadingCells = loadingCells.remove!(c => c == cell);
                }
            }

            if(characterModel)
                characterModel.refreshBuffers(frame.commandBuffer);

            const modelViewProj = wtb.proj * wtb.view * wtb.model;


            if(screenshotPath.length && frameIndex == captureFrame)
                scene.captureFrame(screenshotPath);

            const cellCulling = noGpuCull ? CellCulling.cpu : CellCulling.gpu;
            const shadowViewProj = scene.sunShadow.viewProj * wtb.model;
            const activeCells = streaming ? residency.active() : levelCells;

            scene.recordCommandBuffer(
                frame,
                (buf, phase) {
                    // Blended draws keep the CPU path, which sorts them by depth
                    drawCells(levelIndex, buf, modelViewProj, activeCells,
                        frame.frameSets[0].descriptorSet, phase,
                        phase == DrawPhase.blended ? CellCulling.cpu : cellCulling);

                    if(characterModel && thirdPerson && characterVisible)
                        characterModel.drawingBufferFilling(buf, modelViewProj * characterTransform,
                            frame.frameSets[0].descriptorSet, phase);

                    if(debugCapsuleLines && phase == DrawPhase.surface)
                        debugCapsuleLines.drawingBufferFilling(buf,
                            debugCapsuleLines.pipelineCfg, modelViewProj,
                            frame.frameSets[0].descriptorSet);
                },
                null,
                (buf) {
                    drawCells(levelIndex, buf, shadowViewProj, activeCells,
                        frame.frameSets[0].descriptorSet, DrawPhase.shadow, cellCulling);
                },
                (buf) {
                    if(cellCulling != CellCulling.gpu)
                        return;

                    gatherCells(levelIndex, buf, modelViewProj, activeCells, DrawPhase.surface);
                    gatherCells(levelIndex, buf, shadowViewProj, activeCells, DrawPhase.shadow);
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
