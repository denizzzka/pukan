module pukan.camera_controls;

import dlib.math: Vector3f;
import pukan.fly_camera: FlyCamera, LookAxis;

/// Key and mouse state one frame of a fly camera needs
struct CameraControlState
{
    bool forward, back, left, right;
    bool rollLeft, rollRight;
    bool fast, slow;
    bool resetRoll;
    bool toggleLookAxis;
}

/// Turns cursor and key state into FlyCamera motion; the host maps its window
struct CameraControls
{
    /// Radians per second of a roll key
    float rollSpeed = 1.5f;
    float fastFactor = 4.0f;
    float slowFactor = 0.25f;
    /// World units per pixel of the middle button pan at the base speed
    float panPerPixel = 0.005f;

    private double cursorX;
    private double cursorY;
    private bool cursorKnown;
    private float lookX = 0;
    private float lookY = 0;
    private float panX = 0;
    private float panY = 0;
    private float zoomNotches = 0;
    private bool resetHeld;
    private bool lookAxisHeld;

    /// Feeds a cursor move; look and pan accumulate only while their button is held
    void cursorMoved(double x, double y, bool look, bool pan) nothrow @nogc
    {
        if(cursorKnown)
        {
            const dx = cast(float) (x - cursorX);
            const dy = cast(float) (y - cursorY);

            if(look)
            {
                lookX += dx;
                lookY += dy;
            }

            if(pan)
            {
                panX += dx;
                panY += dy;
            }
        }

        cursorX = x;
        cursorY = y;
        cursorKnown = true;
    }

    /// Feeds wheel notches; positive zooms in
    void scroll(float notches) nothrow @nogc
    {
        zoomNotches += notches;
    }

    void update(ref FlyCamera camera, in CameraControlState state, float dt)
    {
        auto speed = camera.speed;
        if(state.fast)
            speed *= fastFactor;
        if(state.slow)
            speed *= slowFactor;

        const local = Vector3f(
            (state.right ? 1.0f : 0.0f) - (state.left ? 1.0f : 0.0f),
            0,
            (state.forward ? 1.0f : 0.0f) - (state.back ? 1.0f : 0.0f),
        );

        if(dt > 0)
        {
            camera.move(local, speed * dt);
            camera.rollBy(
                ((state.rollLeft ? 1.0f : 0.0f) - (state.rollRight ? 1.0f : 0.0f))
                * rollSpeed * dt);
        }

        if(state.resetRoll && !resetHeld)
            camera.resetRoll();
        resetHeld = state.resetRoll;

        if(state.toggleLookAxis && !lookAxisHeld)
            camera.lookAxis = camera.lookAxis == LookAxis.screen
                ? LookAxis.horizontal
                : LookAxis.screen;
        lookAxisHeld = state.toggleLookAxis;

        if(lookX != 0 || lookY != 0)
        {
            camera.look(lookX, lookY);
            lookX = 0;
            lookY = 0;
        }

        if(panX != 0 || panY != 0)
        {
            const step = speed * panPerPixel;
            camera.pan(panX * step, -panY * step);
            panX = 0;
            panY = 0;
        }

        if(zoomNotches != 0)
        {
            camera.zoom(zoomNotches);
            zoomNotches = 0;
        }
    }
}

unittest
{
    import std.math: isClose;

    auto camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 0, -1));
    camera.lookAxis = LookAxis.screen;

    CameraControls controls;
    controls.cursorMoved(100, 100, true, false);
    controls.cursorMoved(120, 100, true, false);

    CameraControlState state;
    controls.update(camera, state, 0);
    assert(camera.forward.x > 0);

    // A move without the button held is ignored
    const yaw = camera.forward.x;
    controls.cursorMoved(300, 100, false, false);
    controls.update(camera, state, 0);
    assert(isClose(camera.forward.x, yaw, 1e-5f, 1e-5f));
}

unittest
{
    import std.math: isClose;

    auto camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 0, -1));
    camera.speed = 2;

    CameraControls controls;
    CameraControlState state;
    state.forward = true;

    controls.update(camera, state, 0.5f);
    assert(isClose(camera.position.z, -1, 1e-4f, 1e-4f));

    state.fast = true;
    controls.update(camera, state, 0.5f);
    assert(isClose(camera.position.z, -5, 1e-4f, 1e-4f));

    state.fast = false;
    state.slow = true;
    controls.update(camera, state, 0.5f);
    assert(isClose(camera.position.z, -5.25f, 1e-4f, 1e-4f));
}

unittest
{
    import std.math: isClose;

    auto camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 0, -1));
    camera.speed = 2;

    CameraControls controls;
    controls.cursorMoved(0, 0, false, true);
    controls.cursorMoved(100, 50, false, true);

    CameraControlState state;
    controls.update(camera, state, 0);

    assert(isClose(camera.position.x, 100 * 2 * controls.panPerPixel, 1e-4f, 1e-4f));
    assert(isClose(camera.position.y, -50 * 2 * controls.panPerPixel, 1e-4f, 1e-4f));
}

unittest
{
    import std.math: isClose;

    auto camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 0, -1));
    camera.lookAxis = LookAxis.screen;

    CameraControls controls;
    CameraControlState state;
    state.toggleLookAxis = true;

    controls.update(camera, state, 0);
    assert(camera.lookAxis == LookAxis.horizontal);

    controls.update(camera, state, 0);
    assert(camera.lookAxis == LookAxis.horizontal);

    state.toggleLookAxis = false;
    controls.update(camera, state, 0);
    state.toggleLookAxis = true;
    controls.update(camera, state, 0);
    assert(camera.lookAxis == LookAxis.screen);

    const fov = camera.fov;
    controls.scroll(1);
    controls.update(camera, state, 0);
    assert(camera.fov < fov);
    assert(isClose(camera.fov, fov * 0.9f, 1e-4f, 1e-4f));
}
