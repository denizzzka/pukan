import dlib.math: Axis, Matrix4x4f, Vector3f, Vector4f, rotationMatrix;
import pukan;
import pukan.graphics.g3d.axes: axisVector;
import pukan.graphics.g3d.impostor: CellImpostor, Impostors;
import pukan.graphics.g3d.occlusion: DepthRaster, currentOcclusion;
import pukan.graphics.g3d.camera: cameraView, vulkanPerspectiveMatrix;
import pukan.graphics.g3d.fly_camera: FlyCamera;
import pukan.graphics.g3d.portals: PortalGrid, PortalSet, RoomPortal;
import pukan.graphics.g3d.shadow: sunCascadeCount;
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
import pukan.graphics.g3d.pbr.pipelines: LightingMode, lightingMode, oitPass, plainShading;
import pukan.physics.simulation: Simulation;
import pukan.physics.world: CollisionWorld, ShapeCastHit;
import pukan.graphics.g3d.primitives_tree.lines: LineInstance, LineRenderer;
import pukan.graphics.g3d.stats: DrawStats, drawStats;
import pukan.graphics.g2d.ui: Ui, UiScript;
import pukan.vulkan.bindings;
import ImGui = d_imgui;
import d_imgui.imgui_h: ImGuiCond, ImGuiKey, ImGuiTreeNodeFlags, ImVec2;
import pukan.vulkan.core: FlightRecorder, LayerSettings;
import glfw3.api;
import std.algorithm: max, min, remove, sort, sum;
import std.math: PI, abs, atan2, cos, isNaN, sin, sqrt;
import std.exception: enforce;
import std.format: format;
import std.getopt: defaultGetoptPrinter, getopt;
import std.meta: AliasSeq;
import std.stdio: stderr, writeln;
import std.algorithm: endsWith, startsWith;
import std.array: join;
import std.conv: to;
import std.string: split, toStringz;

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

private DepthFormat parseDepthFormat(string name)
{
    switch(name)
    {
        case "32": return DepthFormat.float32Stencil;
        case "24": return DepthFormat.unorm24Stencil;
        default:
            enforce(false, "unknown depth buffer: " ~ name ~ " (24 or 32)");
            assert(false);
    }
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
/// The UI that owns the keyboard and the pointer, null while it is off
private Ui activeUi;
/// Set while a UI window takes the pointer, so the camera leaves it alone
private bool uiCapturing;
/// Wheel notches the UI has not consumed yet
private float pendingWheel;

extern(C) void onCursorPos(GLFWwindow* window, double x, double y) nothrow @nogc
{
    if(uiCapturing)
    {
        controls.forgetCursor();
        return;
    }

    controls.cursorMoved(x, y,
        glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS,
        glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_MIDDLE) == GLFW_PRESS);
}

extern(C) void onScroll(GLFWwindow*, double, double yoffset) nothrow @nogc
{
    pendingWheel += cast(float) yoffset;

    if(!uiCapturing)
        controls.scroll(cast(float) yoffset);
}

extern(C) void onChar(GLFWwindow*, uint codepoint) nothrow @nogc
{
    if(activeUi is null || codepoint == 0 || codepoint > 0x10FFFF)
        return;

    char[4] utf8;
    size_t length;

    if(codepoint < 0x80)
    {
        utf8[0] = cast(char) codepoint;
        length = 1;
    }
    else if(codepoint < 0x800)
    {
        utf8[0] = cast(char) (0xC0 | (codepoint >> 6));
        utf8[1] = cast(char) (0x80 | (codepoint & 0x3F));
        length = 2;
    }
    else if(codepoint < 0x10000)
    {
        utf8[0] = cast(char) (0xE0 | (codepoint >> 12));
        utf8[1] = cast(char) (0x80 | ((codepoint >> 6) & 0x3F));
        utf8[2] = cast(char) (0x80 | (codepoint & 0x3F));
        length = 3;
    }
    else
    {
        utf8[0] = cast(char) (0xF0 | (codepoint >> 18));
        utf8[1] = cast(char) (0x80 | ((codepoint >> 12) & 0x3F));
        utf8[2] = cast(char) (0x80 | ((codepoint >> 6) & 0x3F));
        utf8[3] = cast(char) (0x80 | (codepoint & 0x3F));
        length = 4;
    }

    activeUi.addText(cast(string) utf8[0 .. length]);
}

/// Glyph sets named on the command line
private UiScript[] parseScripts(string value)
{
    import std.array: split;
    import std.exception: enforce;
    import std.string: strip;

    if(value.length == 0)
        return [UiScript.latin, UiScript.cyrillic];

    UiScript[] scripts;

    foreach(name; value.split(","))
    {
        switch(strip(name))
        {
            case "latin": scripts ~= UiScript.latin; break;
            case "cyrillic": scripts ~= UiScript.cyrillic; break;
            case "greek": scripts ~= UiScript.greek; break;
            case "thai": scripts ~= UiScript.thai; break;
            case "vietnamese": scripts ~= UiScript.vietnamese; break;
            case "japanese": scripts ~= UiScript.japanese; break;
            case "korean": scripts ~= UiScript.korean; break;
            case "chinese": scripts ~= UiScript.chineseSimplified; break;
            case "chinese-full": scripts ~= UiScript.chineseFull; break;
            default: enforce(false, "unknown --ui-scripts entry: " ~ name);
        }
    }

    return scripts;
}

/// Queues the window state the UI needs for its next frame
private void feedUi(Ui ui, GLFWwindow* window, VkExtent2D extent, float deltaSeconds)
{
    int frameWidth, frameHeight, windowWidth, windowHeight;
    glfwGetFramebufferSize(window, &frameWidth, &frameHeight);
    glfwGetWindowSize(window, &windowWidth, &windowHeight);

    double cursorX, cursorY;
    glfwGetCursorPos(window, &cursorX, &cursorY);

    const scaleX = frameWidth / cast(float) max(windowWidth, 1);
    const scaleY = frameHeight / cast(float) max(windowHeight, 1);

    ui.setMouse(
        cast(float) cursorX * scaleX,
        cast(float) cursorY * scaleY,
        glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_LEFT) == GLFW_PRESS,
        glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS,
        glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_MIDDLE) == GLFW_PRESS,
        0,
        pendingWheel,
    );
    pendingWheel = 0;

    static immutable struct KeyBinding
    {
        int glfw;
        ImGuiKey imgui;
    }

    static immutable KeyBinding[] bindings = [
        KeyBinding(GLFW_KEY_TAB, ImGuiKey.Tab),
        KeyBinding(GLFW_KEY_LEFT, ImGuiKey.LeftArrow),
        KeyBinding(GLFW_KEY_RIGHT, ImGuiKey.RightArrow),
        KeyBinding(GLFW_KEY_UP, ImGuiKey.UpArrow),
        KeyBinding(GLFW_KEY_DOWN, ImGuiKey.DownArrow),
        KeyBinding(GLFW_KEY_PAGE_UP, ImGuiKey.PageUp),
        KeyBinding(GLFW_KEY_PAGE_DOWN, ImGuiKey.PageDown),
        KeyBinding(GLFW_KEY_HOME, ImGuiKey.Home),
        KeyBinding(GLFW_KEY_END, ImGuiKey.End),
        KeyBinding(GLFW_KEY_INSERT, ImGuiKey.Insert),
        KeyBinding(GLFW_KEY_DELETE, ImGuiKey.Delete),
        KeyBinding(GLFW_KEY_BACKSPACE, ImGuiKey.Backspace),
        KeyBinding(GLFW_KEY_SPACE, ImGuiKey.Space),
        KeyBinding(GLFW_KEY_ENTER, ImGuiKey.Enter),
        KeyBinding(GLFW_KEY_ESCAPE, ImGuiKey.Escape),
        KeyBinding(GLFW_KEY_LEFT_CONTROL, ImGuiKey.LeftCtrl),
        KeyBinding(GLFW_KEY_RIGHT_CONTROL, ImGuiKey.RightCtrl),
        KeyBinding(GLFW_KEY_LEFT_SHIFT, ImGuiKey.LeftShift),
        KeyBinding(GLFW_KEY_RIGHT_SHIFT, ImGuiKey.RightShift),
        KeyBinding(GLFW_KEY_LEFT_ALT, ImGuiKey.LeftAlt),
        KeyBinding(GLFW_KEY_RIGHT_ALT, ImGuiKey.RightAlt),
        KeyBinding(GLFW_KEY_LEFT_SUPER, ImGuiKey.LeftSuper),
        KeyBinding(GLFW_KEY_RIGHT_SUPER, ImGuiKey.RightSuper),
    ];

    foreach(binding; bindings)
        ui.addKey(binding.imgui, glfwGetKey(window, binding.glfw) == GLFW_PRESS);

    ui.beginFrame(deltaSeconds, extent);
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

/// Captures a card for a few cells whose geometry is on the GPU
private void capturePendingCells(
    VkCommandBuffer buf,
    CellIndex!DrawItem index,
    Scene scene,
    Impostors impostors,
    ref CellImpostor[CellCoord] cells,
    ref CellCoord[] pending,
    in Vector3f eye,
    float range,
    VkDescriptorSet frameSet,
)
{
    if(impostors is null || pending.length == 0)
        return;

    // A frame pays for a few captures; the rest wait for the next ones
    enum maxCapturesPerFrame = 8;

    const count = min(cast(size_t) maxCapturesPerFrame, pending.length);
    const taking = pending[0 .. count];
    CellCoord[] waiting;

    foreach(cell; taking)
    {
        if(cell in cells)
            continue;

        const bounds = scene.cellGrid.bounds(cell);
        const center = (bounds.min + bounds.max) * 0.5f;

        // Cards are drawn only within `range`, so farther cells are not worth one
        if((center - eye).length > range)
        {
            waiting ~= cell;
            continue;
        }

        Boxf[] parts;

        foreach(item; index.collect([cell]))
            parts ~= item.bounds;

        const oldMode = lightingMode;
        const oldOit = oitPass;
        lightingMode = LightingMode.unlit;
        oitPass = false;
        scope(exit)
        {
            lightingMode = oldMode;
            oitPass = oldOit;
        }

        const impostor = impostors.capture(buf, parts, eye, (b, viewProj) {
            drawCells(index, b, viewProj, [cell], frameSet, DrawPhase.surface, CellCulling.cpu);
        });

        if(impostor.captured)
            cells[cell] = impostor;
    }

    pending = pending[count .. $] ~ waiting;
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

/// Rooms visible from each room in `pvsSectors` directions, baked once at load
bool[long][long][pvsSectors] pvsBake;

/// Directions the bake samples; the runtime picks the nearest one
enum pvsSectors = 16;

private void bakePvs(ref PortalSet portals, in PortalGrid grid)
{
    import core.time: MonoTime;
    import std.stdio: stderr;

    const began = MonoTime.currTime;
    bool[long][long][] baked;

    foreach(sector; 0 .. pvsSectors)
    {
        bool[long][long] table;

        foreach(x; 0 .. grid.rooms)
            foreach(z; 0 .. grid.rooms)
            {
                const centre = Vector3f(
                    (x + 0.5f) * grid.roomSize,
                    grid.doorwayHeight * 0.65f,
                    (z + 0.5f) * grid.roomSize,
                );

                const yaw = sector * 2.0f * PI / pvsSectors;
                const target = centre + Vector3f(sin(yaw), 0, cos(yaw));
                const viewProj = vulkanPerspectiveMatrix(80.0f, 1.333f, 0.05f, 500.0f)
                    * cameraView(centre, target, Vector3f(0, 1, 0));

                table[cast(long) x * grid.rooms + z] = portals.visibleRooms(
                    [cast(long) x * grid.rooms + z], viewProj);
            }

        baked ~= table;
    }

    pvsBake = baked;

    stderr.writefln("pvs baked in %.1f ms: %s rooms x %s directions",
        (MonoTime.currTime - began).total!"msecs", grid.rooms * grid.rooms, pvsSectors);
}

/// Rooms the bake says a view in the camera's direction is in
private bool[long] bakedRooms(
    in PortalSet portals,
    in PortalGrid grid,
    scope const(long)[] starts,
    in FlyCamera camera,
)
{
    bool[long] seen;

    const yaw = atan2(camera.forward.x, camera.forward.z);
    const sector = cast(size_t) ((yaw + PI) / (2 * PI) * pvsSectors) % pvsSectors;

    foreach(start; starts)
    {
        if(start >= pvsBake[sector].length)
            continue;

        foreach(room, visible; pvsBake[sector][start])
            if(visible)
                seen[room] = true;
    }

    return seen;
}

/// Cell streaming, as the trace and the summary report it
struct StreamTotals
{
    size_t total;
    size_t pending;
    size_t bytes;
    size_t placements;
    double load = 0;
    double unload = 0;
    size_t frames;
}

/// Last frame's streaming counters, for the debug window
struct StreamScreen
{
    size_t active;
    size_t pending;
    size_t nearCells;
    size_t proxyCells;
    size_t farCells;
    size_t placements;
    size_t proxies;
    size_t sparse;
    size_t occluded;
    size_t kernel;
    size_t bytes;
    double load = 0;
    double unload = 0;
}

/// Reports what a screen pixel points at, so a fault can be named and found
private void reportProbe(
    string scenePath,
    CellIndex!DrawItem levelIndex,
    scope const(CellCoord)[] cells,
    scope const(CellCoord)[] nearCells,
    scope const(CellCoord)[] proxyCells,
    scope const(CellCoord)[] farCells,
    in Matrix4x4f viewProj,
    VkExtent2D extent,
    int pixelX,
    int pixelY,
    in FlyCamera camera,
    float nearPlane,
    float farPlane,
    in CellGrid grid,
    CollisionWorld collisionWorld,
    bool characterDrawn,
    in Vector3f characterCenter,
    float characterRadius,
    string characterText,
    string shadowText,
    string path,
)
{
    import std.file: write;

    const inverse = viewProj.inverse;
    const ndcX = 2.0f * (pixelX + 0.5f) / extent.width - 1.0f;
    const ndcY = 2.0f * (pixelY + 0.5f) / extent.height - 1.0f;

    Vector3f unproject(float z)
    {
        const p = Vector4f(ndcX, ndcY, z, 1) * inverse;
        return Vector3f(p.x, p.y, p.z) / p.w;
    }

    const origin = unproject(1);
    const direction = (unproject(0) - origin).normalized;

    string[] lines = [
        format("probe %s,%s of %sx%s", pixelX, pixelY, extent.width, extent.height),
        format("scene   %s", scenePath),
        format("camera  position=%s forward=%s fov=%s near=%s far=%s",
            camera.position, camera.forward, camera.fov, nearPlane, farPlane),
        format("ray     origin=%s direction=%s", origin, direction),
    ];

    DrawItem item;
    float distance;

    if(levelIndex.raycast(cells, origin, direction, float.max, item, distance))
    {
        string partName;

        if(item.part != wholePart)
            partName = (cast(PartDrawable) item.drawable).partName(item.part);
        else if(auto level = cast(GodotScene) item.drawable)
            partName = level.name;
        else if(auto gltf = cast(GlTF) item.drawable)
            partName = gltf.possibleName;

        const point = origin + direction * distance;
        const cell = grid.of(point);

        string ring = "hidden";

        foreach(ringCell; nearCells)
            if(ringCell == cell)
                ring = "near";

        foreach(ringCell; proxyCells)
            if(ringCell == cell)
                ring = "proxy";

        foreach(ringCell; farCells)
            if(ringCell == cell)
                ring = "far";

        if(distance < 1e-3f)
            lines ~= format("hit     \"%s\" ring=%s cell=(%s,%s,%s); camera inside its bounds",
                partName, ring, cell.x, cell.y, cell.z);
        else
            lines ~= format("hit     \"%s\" ring=%s cell=(%s,%s,%s) distance=%s point=%s",
                partName, ring, cell.x, cell.y, cell.z, distance, point);

        lines ~= format("bounds  min=%s max=%s", item.bounds.min, item.bounds.max);
    }
    else
        lines ~= "hit     nothing";

    if(collisionWorld)
    {
        const surface = collisionWorld.raycast(origin, direction);

        if(surface.hit)
            lines ~= format("surface point=%s normal=%s collider=%s",
                surface.point, surface.normal, surface.collider);
        else
            lines ~= "surface none";
    }

    if(characterDrawn)
    {
        const toCenter = characterCenter - origin;
        const along = toCenter.x * direction.x + toCenter.y * direction.y + toCenter.z * direction.z;
        const offAxis = toCenter - direction * along;

        if(along > 0.0f && offAxis.length <= characterRadius)
            lines ~= format("character %s distance=%s", characterText, along);
    }

    lines ~= format("shadows %s", shadowText);
    lines ~= format("cells   %s drawn", cells.length);

    const text = lines.join("\n");
    writeln(text);
    write(path, text ~ "\n");
    writeln("state written to ", path);
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
    bool noLocalShadows;
    bool noSunShadows;
    bool noShadowCache;
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
    string depthOption = "32";
    float cellRange = 128.0f;
    bool noCells;
    bool noGpuCull;
    float impostorDistance = 160.0f;
    float impostorRange = 256.0f;
    float proxyDistance;
    size_t proxyMinParts = 8;
    bool occlusion;
    bool occlusionGpu;
    bool trace;
    float cellSize = 64.0f;
    string portalPath;
    bool pvs;
    bool stats;
    uint warmup;
    string pickOrigin;
    string pickDirection;
    string probeOption;
    uint widthOption = width;
    uint heightOption = height;
    bool uiOption;
    bool noUiOption;
    string[] uiFontOptions;
    float uiFontSize = 16.0f;
    string uiScriptsOption;
    bool uiDemoOption;
    string uiTextOption;

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
        "no-local-shadows", "let the sun cast, but not the local lights", &noLocalShadows,
        "no-sun-shadows", "let the spot lights cast, but not the sun", &noSunShadows,
        "no-shadow-cache", "redraw the shadow maps every frame", &noShadowCache,
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
        "impostor-distance", "draw cells beyond this distance as one captured card, 0 = off", &impostorDistance,
        "proxy-distance", "merge the parts of cells beyond this distance into one proxy, 0 = off", &proxyDistance,
        "proxy-min-parts", "parts a cell needs before a proxy is worth its merge", &proxyMinParts,
        "occlusion", "skip parts the near ones hide, tested against a coarse CPU depth grid", &occlusion,
        "occlusion-gpu", "let the cull kernel drop instances the last frame's depth covers", &occlusionGpu,
        "trace", "print a line whenever cells enter or leave, with the frame cost", &trace,
        "cell-size", "extent of a streaming cell in metres, 64 by default", &cellSize,
        "portals", "walk this room grid and draw only the rooms its doorways reach", &portalPath,
        "pvs", "bake the room visibility per direction at load and skip the walk", &pvs,
        "impostor-range", "keep the card of a dropped cell until this distance", &impostorRange,
        "stats", "report draws, triangles and frame time per ring at the end", &stats,
        "warmup", "frames the stats leave out, for loading and merging", &warmup,
        "pick", "report what a ray from this point hits, x,y,z", &pickOrigin,
        "pick-dir", "ray direction for --pick, x,y,z", &pickDirection,
        "probe", "report what the scene shows at screen pixel x,y", &probeOption,
        "width", "window or offscreen width in pixels, 800 by default", &widthOption,
        "height", "window or offscreen height in pixels, 600 by default", &heightOption,
        "ui", "draw the debug UI over the frame, on by default in a window", &uiOption,
        "no-ui", "run without the debug UI", &noUiOption,
        "ui-font", "TrueType font for the debug UI, repeatable so a second font covers other scripts; the built-in font covers ASCII only", &uiFontOptions,
        "ui-font-size", "font size in pixels, 16 by default", &uiFontSize,
        "ui-scripts", "glyph sets to bake with --ui-font: latin, cyrillic, greek, thai, vietnamese, japanese, korean, chinese, chinese-full", &uiScriptsOption,
        "ui-demo", "open the Dear ImGui demo window", &uiDemoOption,
        "ui-text", "draw this text in a corner window, to check the font and its glyph sets", &uiTextOption,
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
        "depth", "depth buffer: 32 (float, default) or 24 (unorm)", &depthOption,
    );

    if(getoptResult.helpWanted)
    {
        defaultGetoptPrinter("pukan Godot scene demo", getoptResult.options);
        return;
    }

    int probePixelX;
    int probePixelY;
    bool probePending;
    bool probeFromKeyboard;
    bool probeKeyWasDown;

    if(probeOption.length)
    {
        const pixel = probeOption.split(",");

        enforce(pixel.length == 2, "--probe takes x,y");
        probePixelX = pixel[0].to!int;
        probePixelY = pixel[1].to!int;
        probePending = true;
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

    const depthFormat = parseDepthFormat(depthOption);

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

        window = glfwCreateWindow(cast(int) widthOption, cast(int) heightOption,
            "pukan Godot scene".toStringz, null, null);
        enforce(window, "Cannot create a window");
        glfwSetCursorPosCallback(window, &onCursorPos);
        glfwSetScrollCallback(window, &onScroll);
        glfwSetCharCallback(window, &onChar);
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
        scene = new Scene(device, VkExtent2D(widthOption, heightOption),
            VK_FORMAT_R8G8B8A8_SRGB, "demo_godot", depthFormat);
    else
        scene = new Scene(device, surface, &windowSizeChanged, surfaceFormat, "demo_godot", depthFormat);
    scope(exit) destroy(scene);

    writeln("depth: ", scene.renderPass.depthFormat);
    scene.frameRateLimit = offscreen ? 0 : 60;

    if((!offscreen || uiOption) && !noUiOption)
    {
        auto ui = scene.enableUi();
        activeUi = ui;

        foreach(index, path; uiFontOptions)
            ui.addFont(path, uiFontSize, parseScripts(uiScriptsOption), uiTextOption,
                index != 0);
    }

    Impostors impostors;
    scope(exit) if(impostors) destroy(impostors);

    if(impostorDistance > 0)
        impostors = new Impostors(device, scene.pipelineFactory, scene.renderPass,
            scene.renderPass.imageFormat);

    CellImpostor[CellCoord] cellImpostors;

    scene.sunShadow.enabled = !noShadows && !noSunShadows;
    scene.sunShadow.cache = !noShadowCache;
    scene.localShadow.enabled = !noShadows && !noLocalShadows;
    scene.localShadow.cache = !noShadowCache;
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

    godotScene.proxyMinParts = proxyMinParts;

    if(occlusion || occlusionGpu)
        scene.enableOcclusionDepth(192, 144);

    PortalGrid portals;
    PortalSet portalSet;
    const bool hasPortals = portalPath.length != 0;

    if(hasPortals)
    {
        portals = PortalGrid.load(portalPath);

        // A level that authors its own doorways names a node for each of them
        godotScene.eachNode((string name, in Matrix4x4f world) {
            if(!name.startsWith("Portal_"))
                return;

            const parts = name.split("_");

            if(parts.length != 4)
                return;

            const x = parts[1].to!int;
            const z = parts[2].to!int;
            const side = parts[3].to!int;

            long other;

            final switch(side)
            {
                case 0: other = cast(long) x * portals.rooms + (z - 1); break;
                case 1: other = cast(long) x * portals.rooms + (z + 1); break;
                case 2: other = cast(long) (x - 1) * portals.rooms + z; break;
                case 3: other = cast(long) (x + 1) * portals.rooms + z; break;
            }

            RoomPortal portal;
            portal.a = cast(long) x * portals.rooms + z;
            portal.b = other;

            foreach(i; 0 .. 4)
            {
                const u = (i == 0 || i == 3) ? -0.5f : 0.5f;
                const v = (i < 2) ? -0.5f : 0.5f;
                const corner = Vector4f(u, v, 0, 1) * world;
                portal.corners[i] = Vector3f(corner.x, corner.y, corner.z);
            }

            portalSet.portals ~= portal;
        });

        // A level without portal nodes falls back to what the grid implies
        if(portalSet.portals.length == 0)
            portalSet.portals = portals.portals();

        if(pvs)
            bakePvs(portalSet, portals);
    }

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
                scene.addPointLight(light.position, light.color * light.energy * 8.0f, light.range);
                break;

            case GodotLightKind.spot:
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
            Vector3f(cellSize, levelBounds.max.y - levelBounds.min.y + 2, cellSize),
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
            ? "character: WASD move, right mouse look, middle mouse orbit, Space jump, V third person, P probe"
            : "camera: WASD move, right mouse look, middle mouse pan, wheel zoom, Q/E roll, R reset roll, H look axis (horizontal), P probe");

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

    // Cards are captured only for cells the streaming loaded
    CellCoord[] pendingCaptures;

    if(streaming)
    {
        residency.update([
            cameraSource(cellRange, CellState.active),
            cameraSource(cellRange * 1.5f, CellState.loaded),
        ], 0);

        scope initialCells = residency.active() ~ residency.take(size_t.max);
        pendingCaptures ~= initialCells;

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
    /// Bytes of merged geometry a frame may upload for new proxies
    enum proxyBuildBudget = 1 << 20;
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
    /// Parts the coarse occlusion grid left out
    size_t occludedTotal;
    /// Instances the cull kernel's grid dropped
    size_t kernelOccluded;
    StreamTotals streamCells;
    StreamScreen streamScreen;
    bool[CellCoord] knownCells;
    size_t bytesTotal;
    size_t borderEntered;
    size_t borderLeft;
    size_t borderActive;
    size_t borderPending;
    double borderLoad = 0;
    double borderUnload = 0;
    /// Per ring: near cells, proxies, cards
    DrawStats[3] ringTotals;
    DrawStats shadowTotal;
    size_t[3] cellTotals;
    double[] frameTimes;
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
    bool uiDemoWindow = uiDemoOption;
    bool uiKeyWasDown;
    bool uiDebugOpen = true;
    float smoothedDt = 0;

    while((offscreen ? frameIndex < frames : !glfwWindowShouldClose(window)) && (frames == 0 || frameIndex < frames))
    {
        ++frameIndex;
        const frameBegan = MonoTime.currTime;
        if(!offscreen)
            glfwPollEvents();

        const now = offscreen ? (MonoTime.currTime - start).total!"msecs" * 0.001 : glfwGetTime();
        const measuredDt = cast(float) (now - lastTime < 0.1 ? now - lastTime : 0.1);
        const dt = fixedStep || offscreen
            ? cast(float) (1.0 / physicsHz)
            : measuredDt;
        lastTime = now;

        if(measuredDt > 0)
            smoothedDt = smoothedDt <= 0 ? measuredDt : smoothedDt * 0.9f + measuredDt * 0.1f;

        if(scene.ui !is null)
        {
            if(!offscreen)
            {
                const bool uiKey = glfwGetKey(window, GLFW_KEY_F1) == GLFW_PRESS;

                if(uiKey && !uiKeyWasDown)
                    uiDemoWindow = !uiDemoWindow;

                uiKeyWasDown = uiKey;

                feedUi(scene.ui, window, scene.swapChain.imageExtent, dt);
                uiCapturing = scene.ui.capturesMouse();
            }
            else
                scene.ui.beginFrame(dt, scene.swapChain.imageExtent);

            if(uiDebugOpen)
            {
                ImGui.SetNextWindowPos(ImVec2(16, 16), ImGuiCond.FirstUseEver);
                ImGui.SetNextWindowSize(ImVec2(330, 520), ImGuiCond.FirstUseEver);

                if(ImGui.Begin("Debug", &uiDebugOpen))
                {
                    ImGui.Text("frame %d   %.1f fps   %.2f ms",
                        cast(int) frameIndex,
                        smoothedDt > 0 ? 1.0f / smoothedDt : 0.0f,
                        smoothedDt * 1000.0f);

                    if(ImGui.CollapsingHeader("Lights", ImGuiTreeNodeFlags.DefaultOpen))
                    {
                        ImGui.Text("selected %d of %d", cast(int) scene.selectedLightCount,
                            cast(int) scene.activeLightCount);
                        ImGui.Text("cascades %d   tiles %d", sunCascadeCount,
                            cast(int) scene.localShadow.active);
                        ImGui.Text("sun shadow %s   local shadow %s",
                            scene.sunShadow.enabled ? "on" : "off",
                            scene.localShadow.enabled ? "on" : "off");

                        ImGui.Checkbox("Sun shadows", &scene.sunShadow.enabled);
                        ImGui.Checkbox("Local shadows", &scene.localShadow.enabled);
                        ImGui.Checkbox("Shadow cache", &scene.sunShadow.cache);
                    }

                    if(ImGui.CollapsingHeader("Tonemapping", ImGuiTreeNodeFlags.DefaultOpen))
                    {
                        int mode = cast(int) scene.tonemapMode;
                        string[] modes = ["Linear", "Reinhard", "Filmic", "ACES", "AgX"];

                        if(ImGui.Combo("Mode", &mode, modes, cast(int) modes.length))
                            scene.tonemapMode = cast(uint) mode;

                        ImGui.SliderFloat("Exposure", &scene.exposure, 0.1f, 4.0f);
                        ImGui.SliderFloat("White", &scene.tonemapWhite, 0.5f, 4.0f);
                        ImGui.SliderFloat("IBL", &scene.iblIntensity, 0.0f, 4.0f);
                    }

                    if(ImGui.CollapsingHeader("Renderer", ImGuiTreeNodeFlags.DefaultOpen))
                    {
                        const frameStats = drawStats();

                        ImGui.Text("draws %d   instances %d", cast(int) frameStats.draws,
                            cast(int) frameStats.instances);
                        ImGui.Text("triangles %d", cast(int) frameStats.triangles);

                        const life = scene.pipelineFactory.lifetime();
                        ImGui.Text("pipelines %d live, %d tracked",
                            cast(int) life.live, cast(int) life.tracked);

                        if(life.tracked)
                            ImGui.Text("oldest used %d frames ago",
                                cast(int) (life.currentFrame - life.oldestUse));

                        ImGui.Checkbox("OIT", &scene.oitEnabled);

                        float fpsCap = cast(float) scene.frameRateLimit;
                        if(ImGui.SliderFloat("FPS cap", &fpsCap, 0.0f, 240.0f, "%.0f fps"))
                            scene.frameRateLimit = fpsCap;
                    }

                    if(ImGui.CollapsingHeader("Streaming", ImGuiTreeNodeFlags.DefaultOpen))
                    {
                        ImGui.Text("cells %d   pending %d", cast(int) streamScreen.active,
                            cast(int) streamScreen.pending);
                        ImGui.Text("near %d   proxy %d   cards %d",
                            cast(int) streamScreen.nearCells,
                            cast(int) streamScreen.proxyCells,
                            cast(int) streamScreen.farCells);
                        ImGui.Text("drawables %d   proxies %d   sparse %d",
                            cast(int) streamScreen.placements,
                            cast(int) streamScreen.proxies,
                            cast(int) streamScreen.sparse);
                        ImGui.Text("bytes %d   load %.2f ms   unload %.2f ms",
                            cast(int) streamScreen.bytes,
                            streamScreen.load, streamScreen.unload);
                        ImGui.Text("occluded %d   kernel %d",
                            cast(int) streamScreen.occluded,
                            cast(int) streamScreen.kernel);

                        if(trace)
                            ImGui.Text("border +%d -%d   %d active",
                                cast(int) borderEntered, cast(int) borderLeft,
                                cast(int) borderActive);
                    }

                    if(ImGui.CollapsingHeader("Camera"))
                    {
                        ImGui.Text("position %.2f %.2f %.2f",
                            camera.position.x, camera.position.y, camera.position.z);
                        ImGui.Text("fov %.0f   near %.3f   far %.0f",
                            fovOption, nearOption, farOption);
                    }

                    if(characterMode)
                        ImGui.Text("character %.2f %.2f %.2f",
                            characterRenderPosition.x, characterRenderPosition.y,
                            characterRenderPosition.z);

                    ImGui.Separator();

                    if(ImGui.Button("Probe center"))
                    {
                        probePixelX = cast(int) scene.swapChain.imageExtent.width / 2;
                        probePixelY = cast(int) scene.swapChain.imageExtent.height / 2;
                        probePending = true;
                    }

                    ImGui.SameLine();

                    if(ImGui.Button("Screenshot"))
                        scene.captureFrame(format("ui-%s.png", frameIndex));
                }

                ImGui.End();
            }

            if(uiDemoWindow)
                ImGui.ShowDemoWindow(&uiDemoWindow);

            if(uiTextOption.length)
            {
                ImGui.SetNextWindowPos(ImVec2(16, 16));
                if(ImGui.Begin("Text"))
                    ImGui.Text("%s", uiTextOption);
                ImGui.End();
            }
        }

        if(characterMode)
        {
            if(!offscreen && !uiCapturing)
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
        else if(!offscreen && !uiCapturing)
            updateCamera(camera, window, dt);

        if(!offscreen && !uiCapturing)
        {
            const bool probeKey = glfwGetKey(window, GLFW_KEY_P) == GLFW_PRESS;

            if(probeKey && !probeKeyWasDown)
            {
                int fbWidth, fbHeight;
                int windowWidth, windowHeight;

                glfwGetFramebufferSize(window, &fbWidth, &fbHeight);
                glfwGetWindowSize(window, &windowWidth, &windowHeight);

                double cursorX, cursorY;
                glfwGetCursorPos(window, &cursorX, &cursorY);

                // A held look button owns the cursor, so the crosshair probes then
                const bool captured =
                    glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_RIGHT) == GLFW_PRESS
                    || glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_MIDDLE) == GLFW_PRESS;

                probePixelX = captured
                    ? fbWidth / 2
                    : cast(int) (cursorX * fbWidth / max(windowWidth, 1));
                probePixelY = captured
                    ? fbHeight / 2
                    : cast(int) (cursorY * fbHeight / max(windowHeight, 1));
                probePending = true;
                probeFromKeyboard = true;
            }

            probeKeyWasDown = probeKey;
        }

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

        scene.drawNextFrame((ref FrameBuilder fb, ref Frame frame, RenderTarget renderTarget) {
            {
                DefaultRenderPass.VariableData renderData;
                renderData.common.imageExtent = renderTarget.extent;
                renderData.common.frameBuffer = frame.frameBuffer;
                scene.renderPass.updateData(renderData);
            }

            scene.updateFrameUniforms(frame, 0, wtb);
            godotScene.refreshBuffers(frame.commandBuffer);

            double loadMs = 0;
            double unloadMs = 0;
            size_t frameBytes = 0;

            if(streaming)
            {
                const loadBegan = MonoTime.currTime;

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
                    bytesTotal += used;
                    frameBytes += used;

                    // Zero bytes means the cell has everything it needs
                    if(used > 0)
                        stillLoading ~= cell;
                    else
                        pendingCaptures ~= cell;
                }

                loadingCells = stillLoading;
                loadMs = (MonoTime.currTime - loadBegan).total!"msecs";

                const unloadBegan = MonoTime.currTime;

                foreach(cell; residency.release(frameIndex))
                {
                    godotScene.releaseProxy(cell);
                    releaseCells(levelIndex, [cell]);
                    loadingCells = loadingCells.remove!(c => c == cell);
                }

                unloadMs = (MonoTime.currTime - unloadBegan).total!"msecs";
            }

            if(characterModel)
                characterModel.refreshBuffers(frame.commandBuffer);

            const modelViewProj = wtb.proj * wtb.view * wtb.model;


            if(screenshotPath.length && frameIndex == captureFrame)
                scene.captureFrame(screenshotPath);

            const cellCulling = noGpuCull ? CellCulling.cpu : CellCulling.gpu;
            CellCoord[] activeCells = (streaming ? residency.active() : levelCells).dup;
            // A room behind a wall still casts a shadow into the rooms in view
            CellCoord[] shadowCells = activeCells;

            if(hasPortals)
            {
                const starts = PortalSet.startRooms(camera.position, portals.roomSize, portals.rooms);
                const seen = pvs
                    ? bakedRooms(portalSet, portals, starts, camera)
                    : portalSet.visibleRooms(starts, modelViewProj);
                CellCoord[] reached;

                foreach(cell; activeCells)
                {
                    const bounds = scene.cellGrid.bounds(cell);
                    const centre = (bounds.min + bounds.max) * 0.5f;

                    int roomX, roomZ;
                    portals.roomOf(centre, roomX, roomZ);

                    if((cast(long) roomX * portals.rooms + roomZ) in seen)
                        reached ~= cell;
                }

                activeCells = reached;
            }

            const placements = levelIndex.placementsIn(activeCells);

            streamScreen.active = activeCells.length;
            streamScreen.pending = residency.pending.length;
            streamScreen.placements = placements;
            streamScreen.proxies = godotScene.proxyCount;
            streamScreen.sparse = godotScene.sparseCount;
            streamScreen.bytes = frameBytes;
            streamScreen.load = loadMs;
            streamScreen.unload = unloadMs;

            if(frameIndex > warmup)
            {
                streamCells.total += activeCells.length;
                streamCells.pending += residency.pending.length;
                streamCells.bytes += bytesTotal;
                streamCells.placements += placements;
                streamCells.load += loadMs;
                streamCells.unload += unloadMs;
                streamCells.frames += 1;
            }

            if(trace)
            {
                bool[CellCoord] current;

                foreach(cell; activeCells)
                    current[cell] = true;

                size_t entered;
                size_t left;

                foreach(cell; activeCells)
                    entered += cell !in knownCells;

                foreach(cell; knownCells.byKey)
                    left += cell !in current;

                knownCells = current;

                borderEntered = entered;
                borderLeft = left;
                borderActive = activeCells.length;
                borderPending = residency.pending.length;
                borderLoad = loadMs;
                borderUnload = unloadMs;
            }

            // A proxy is built as soon as its cell is loaded, so crossing the
            // proxy distance never shows the parts; a frame pays for a few
            size_t proxyBytes;

            foreach(cell; activeCells)
            {
                if(proxyBytes >= proxyBuildBudget)
                    break;

                proxyBytes += godotScene.buildProxy(cell, levelIndex, frame.commandBuffer);
            }

            // A captured cell draws as one card; the rest keep their parts
            CellCoord[] nearCells;
            CellCoord[] farCells;
            CellCoord[] proxyCells;
            bool[CellCoord] activeCellsLookup;

            foreach(cell; activeCells)
            {
                activeCellsLookup[cell] = true;

                const bounds = scene.cellGrid.bounds(cell);
                const center = (bounds.min + bounds.max) * 0.5f;
                const distance = (center - camera.position).length;

                if(impostors !is null && distance > impostorDistance && (cell in cellImpostors))
                    farCells ~= cell;
                else if(proxyDistance > 0 && distance > proxyDistance && godotScene.hasProxy(cell))
                    proxyCells ~= cell;
                else
                    nearCells ~= cell;
            }

            // A cell the streaming dropped keeps showing its card from farther away
            if(impostors !is null)
                foreach(cell, impostor; cellImpostors)
                {
                    if(cell in activeCellsLookup)
                        continue;

                    if((impostor.center - camera.position).length > impostorRange)
                        continue;

                    farCells ~= cell;
                }

            streamScreen.nearCells = nearCells.length;
            streamScreen.proxyCells = proxyCells.length;
            streamScreen.farCells = farCells.length;

            if(probePending && (probeFromKeyboard || frameIndex == captureFrame))
            {
                const reportPath = format("probe-%s-%s-%s.txt", frameIndex, probePixelX, probePixelY);
                const shadowText = format("sun=%s local=%s tiles=%s lights=%s/%s",
                    scene.sunShadow.enabled, scene.localShadow.enabled,
                    scene.localShadow.active, scene.selectedLightCount, scene.activeLightCount);

                reportProbe(scenePath, levelIndex, activeCells, nearCells, proxyCells, farCells,
                    modelViewProj, scene.swapChain.imageExtent, probePixelX, probePixelY, camera,
                    nearPlane, farPlane, scene.cellGrid, collisionWorld,
                    characterModel !is null && characterMode,
                    (mover ? mover.state.position : characterRenderPosition)
                        + scene.up.axisVector * (characterBody.height * 0.5f),
                    max(characterBody.radius, characterBody.height * 0.5f),
                    format("model=%s position=%s motion=%s",
                        modelOption.length ? modelOption : "demo/assets/motion/UAL1_Standard_RM.glb",
                        mover ? mover.state.position : characterRenderPosition,
                        motionReady),
                    shadowText, reportPath);

                if(probeFromKeyboard)
                    scene.captureFrame(reportPath[0 .. $ - 4] ~ ".png");

                probePending = false;
                probeFromKeyboard = false;
            }

            DepthRaster raster;
            scope(exit) currentOcclusion = null;

            if(occlusion)
            {
                raster.reset(192, 144);

                // The depth of a frame that has finished, so no test tears
                scene.readOcclusionDepths(raster.samples);

                currentOcclusion = &raster;
            }

            scene.recordCommandBuffer(
                frame,
                (buf, view, layout, phase) {
                    // The ring split is a surface matter; the other phases draw all
                    const measure = phase == DrawPhase.surface && frameIndex > warmup;
                    auto ringStart = drawStats();

                    // Blended draws keep the CPU path, which sorts them by depth
                    drawCells(levelIndex, buf, modelViewProj, nearCells,
                        frame.frameSets[0].descriptorSet, phase,
                        phase == DrawPhase.blended ? CellCulling.cpu : cellCulling);

                    if(measure)
                    {
                        ringTotals[0] += drawStats() - ringStart;
                        ringStart = drawStats();
                    }

                    // A cell beyond the proxy distance draws as one merged mesh
                    foreach(cell; proxyCells)
                        if(!godotScene.drawProxy(buf, cell, modelViewProj,
                            frame.frameSets[0].descriptorSet, phase))
                            drawCells(levelIndex, buf, modelViewProj, [cell],
                                frame.frameSets[0].descriptorSet, phase, CellCulling.cpu);

                    if(measure)
                    {
                        ringTotals[1] += drawStats() - ringStart;
                        ringStart = drawStats();
                    }

                    if(phase == DrawPhase.surface)
                        foreach(cell; farCells)
                            if(auto impostor = cell in cellImpostors)
                                impostors.draw(buf, *impostor, modelViewProj);

                    if(measure)
                        ringTotals[2] += drawStats() - ringStart;

                    if(characterModel && thirdPerson && characterVisible)
                        characterModel.drawingBufferFilling(buf, modelViewProj * characterTransform,
                            frame.frameSets[0].descriptorSet, phase);

                    if(debugCapsuleLines && phase == DrawPhase.surface)
                        debugCapsuleLines.drawingBufferFilling(buf,
                            debugCapsuleLines.pipelineCfg, modelViewProj,
                            frame.frameSets[0].descriptorSet);
                },
                null,
                (buf, cascade) {
                    auto shadowStart = drawStats();
                    const shadowViewProj = scene.sunShadow.cascades.viewProj[cascade] * wtb.model;

                    // Each cascade keeps only the casters its own frustum sees
                    drawCells(levelIndex, buf, shadowViewProj, shadowCells,
                        frame.frameSets[0].descriptorSet, DrawPhase.shadow, cellCulling, cascade);

                    foreach(cell; proxyCells)
                        if(!godotScene.drawProxy(buf, cell, shadowViewProj,
                            frame.frameSets[0].descriptorSet, DrawPhase.shadow))
                            drawCells(levelIndex, buf, shadowViewProj, [cell],
                                frame.frameSets[0].descriptorSet, DrawPhase.shadow, CellCulling.cpu);

                    shadowTotal += drawStats() - shadowStart;
                },
                (buf, tile) {
                    auto localStart = drawStats();
                    const localViewProj = scene.localShadow.viewProj[tile] * wtb.model;

                    // A local light sees only its cone; cells behind a wall still cast
                    drawCells(levelIndex, buf, localViewProj, shadowCells,
                        frame.frameSets[0].descriptorSet, DrawPhase.shadow, CellCulling.cpu);

                    foreach(cell; proxyCells)
                        if(!godotScene.drawProxy(buf, cell, localViewProj,
                            frame.frameSets[0].descriptorSet, DrawPhase.shadow))
                            drawCells(levelIndex, buf, localViewProj, [cell],
                                frame.frameSets[0].descriptorSet, DrawPhase.shadow, CellCulling.cpu);

                    shadowTotal += drawStats() - localStart;

                },
                (buf) {
                    capturePendingCells(buf, levelIndex, scene, impostors, cellImpostors,
                        pendingCaptures, camera.position, impostorRange,
                        frame.frameSets[0].descriptorSet);

                    if(cellCulling != CellCulling.gpu)
                        return;

                    if(!scene.sunShadow.enabled)
                        return;

                    foreach(cascade; 0 .. sunCascadeCount)
                        if(scene.shadowPending(frame, cascade))
                            gatherCells(levelIndex, buf,
                                scene.sunShadow.cascades.viewProj[cascade] * wtb.model,
                                shadowCells, DrawPhase.shadow, cascade);
                },
                (buf, view, layout) {
                    if(cellCulling != CellCulling.gpu)
                        return;

                    gatherCells(levelIndex, buf, modelViewProj, nearCells, DrawPhase.surface, view);
                },
            );

            streamScreen.occluded = raster.rejected;
            streamScreen.kernel = scene.occlusionRejections;

            if(frameIndex > warmup)
            {
                occludedTotal += raster.rejected;
                kernelOccluded += scene.occlusionRejections;
                cellTotals[0] += nearCells.length;
                cellTotals[1] += proxyCells.length;
                cellTotals[2] += farCells.length;
            }
        });

        const frameMs = (MonoTime.currTime - frameBegan).total!"msecs";

        if(frameIndex > warmup)
            frameTimes ~= frameMs;

        // A border crossing is where a hitch has to be attributed
        if(trace && (borderEntered || borderLeft || frameIndex == 1))
            stderr.writefln(
                "f%5s active %4s pending %3s +%2s -%2s load %6.2f unload %5.2f frame %6.2f",
                frameIndex, borderActive, borderPending, borderEntered, borderLeft,
                borderLoad, borderUnload, frameMs);

        if(screenshotPath.length && frameIndex == captureFrame)
            writeln("screenshot saved to ", screenshotPath);
    }

    reportStats(stats, frameIndex - min(frameIndex, warmup), ringTotals, shadowTotal, cellTotals, frameTimes,
        godotScene.proxyCount, godotScene.sparseCount, occludedTotal, kernelOccluded, streamCells);

    if(characterMode)
        writeln("character position ", mover.state.position,
            " max height ", characterMaxHeight,
            " onGround ", mover.state.onGround);

    vkDeviceWaitIdle(device.device);
}

/// Prints what a frame submitted per ring, so the HLOD rings compare by number
private void reportStats(
    bool enabled,
    uint frames,
    scope const DrawStats[3] rings,
    in DrawStats shadow,
    scope const(size_t)[3] cells,
    scope const(double)[] frameTimes,
    size_t proxies,
    size_t sparse,
    size_t occluded,
    size_t kernelOccluded,
    in StreamTotals streamCells,
)
{
    if(!enabled)
        return;

    const count = max(frames, 1u);

    writeln("frames ", frames,
        "  cells near ", cells[0] / count,
        " proxy ", cells[1] / count,
        " far ", cells[2] / count,
        "  merged ", proxies, " sparse ", sparse, " occluded ", occluded / count,
        " kernel ", kernelOccluded / count);

    if(streamCells.frames)
    {
        const framesRun = cast(double) streamCells.frames;

        writeln(format("stream  cells %6.1f  pending %5.1f  drawables/cell %5.1f  bytes/frame %8.0f  load %.2f ms  unload %.2f ms",
            streamCells.total / framesRun, streamCells.pending / framesRun,
            streamCells.placements / max(cast(double) streamCells.total, 1),
            streamCells.bytes / framesRun, streamCells.load / framesRun, streamCells.unload / framesRun));
    }

    writeln(format("%-7s %8s %10s %12s", "ring", "draws", "instances", "triangles"));

    void row(string name, in DrawStats ring)
    {
        writeln(format("%-7s %8.1f %10.1f %12.0f", name,
            cast(double) ring.draws / count,
            cast(double) ring.instances / count,
            cast(double) ring.triangles / count));
    }

    foreach(i, name; ["near", "proxy", "far"])
        row(name, rings[i]);

    row("shadow", shadow);

    if(frameTimes.length == 0)
        return;

    auto sorted = frameTimes.dup.sort;

    writeln(format("frame mean %.2f ms, p50 %.2f, p95 %.2f, min %.2f, max %.2f",
        sorted.sum / sorted.length,
        sorted[sorted.length / 2],
        sorted[cast(size_t) (sorted.length * 95 / 100)],
        sorted[0],
        sorted[$ - 1]));
}
