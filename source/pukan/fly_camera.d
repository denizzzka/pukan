module pukan.fly_camera;

import dlib.math: Matrix4x4f, Quaternionf, Vector3f, cross, degtorad, dot, rotationQuaternion;
import pukan.scene: cameraTransform, cameraView;
import std.algorithm: clamp;
import std.math: isClose, pow;

private enum worldUp = Vector3f(0, 1, 0);
private enum cameraRight = Vector3f(1, 0, 0);
private enum cameraUp = Vector3f(0, 1, 0);
private enum cameraBack = Vector3f(0, 0, 1);
private enum cameraForward = Vector3f(0, 0, -1);

private enum minFov = 10.0f;
private enum maxFov = 120.0f;
private enum zoomStep = 0.9f;

/// Free-flying camera stored as a quaternion, so it passes the poles freely
struct FlyCamera
{
    /// Units per second of `move`
    float speed = 8.0f;
    Vector3f position = Vector3f(0, 0, 0);
    /// Rotation from camera space to world space
    Quaternionf orientation = Quaternionf(0, 0, 0, 1);
    float fov = 45.0f;

    /// A camera at `eye` whose -Z axis points at `target`
    static FlyCamera lookingAt(Vector3f eye, Vector3f target)
    {
        FlyCamera result;
        result.position = eye;
        result.orientation = orientationOf(cameraTransform(eye, target, worldUp));
        return result;
    }

    /// The camera whose view matrix is `view`, so its first frame matches it
    static FlyCamera fromView(in Matrix4x4f view)
    {
        const transform = view.inverse;

        FlyCamera result;
        result.position = Vector3f(transform.a14, transform.a24, transform.a34);
        result.orientation = orientationOf(transform);
        return result;
    }

    Vector3f forward() const
    {
        return rotate(cameraForward);
    }

    /// Camera right axis, so movement follows the roll
    Vector3f right() const
    {
        return rotate(cameraRight);
    }

    Vector3f up() const
    {
        return rotate(cameraUp);
    }

    Matrix4x4f view() const
    {
        return cameraView(position, position + forward, up);
    }

    /// `dx` and `dy` are cursor pixels; moving right turns right, moving down looks down.
    /// Both axes are the camera's own, so a roll turns the mouse with the view
    void look(float dx, float dy, float sensitivity = 0.003f)
    {
        const yaw = rotationQuaternion(cameraUp, -dx * sensitivity);
        orientation = (orientation * yaw).normalized();

        const pitch = rotationQuaternion(cameraRight, -dy * sensitivity);
        orientation = (orientation * pitch).normalized();
    }

    /// Moves along `local` (x right, y world up, z forward) by `distance` units
    void move(Vector3f local, float distance)
    {
        const direction = right * local.x + worldUp * local.y + forward * local.z;

        if(direction.lengthsqr == 0)
            return;

        position += direction.normalized * distance;
    }

    /// Moves in the screen plane by the two world distances
    void pan(float rightDistance, float upDistance)
    {
        position += right * rightDistance + up * upDistance;
    }

    /// Wheel notches: positive zooms in by narrowing the field of view
    void zoom(float notches)
    {
        fov = clamp(fov * pow(zoomStep, notches), minFov, maxFov);
    }

    void rollBy(float radians)
    {
        orientation = (orientation * rotationQuaternion(cameraBack, radians)).normalized();
    }

    /// Keeps the view direction and drops the roll
    void resetRoll()
    {
        const forward = this.forward;

        auto reference = worldUp;
        if(cross(forward, reference).length < 1e-6f)
            reference = cameraBack;

        const right = cross(forward, reference).normalized();
        const up = cross(right, forward);

        Matrix4x4f basis = Matrix4x4f.identity;
        basis.a11 = right.x;    basis.a21 = right.y;    basis.a31 = right.z;
        basis.a12 = up.x;       basis.a22 = up.y;       basis.a32 = up.z;
        basis.a13 = -forward.x; basis.a23 = -forward.y; basis.a33 = -forward.z;

        orientation = orientationOf(basis);
    }

    /// Keeps only the rotation of a scene transform, which may carry a scale.
    /// dlib builds quaternion matrices transposed to its camera transforms
    private static Quaternionf orientationOf(in Matrix4x4f transform)
    {
        const right = Vector3f(transform.a11, transform.a21, transform.a31).normalized;
        const back = Vector3f(transform.a13, transform.a23, transform.a33).normalized;
        const up = cross(back, right);

        Matrix4x4f basis = Matrix4x4f.identity;
        basis.a11 = right.x; basis.a21 = right.y; basis.a31 = right.z;
        basis.a12 = up.x;    basis.a22 = up.y;    basis.a32 = up.z;
        basis.a13 = back.x;  basis.a23 = back.y;  basis.a33 = back.z;

        return Quaternionf.fromMatrix(basis.transposed).normalized();
    }

    private Vector3f rotate(Vector3f v) const
    {
        Quaternionf q = orientation;
        return q.rotate(v);
    }
}

private bool sameView(in Matrix4x4f a, in Matrix4x4f b)
{
    foreach(i; 0 .. 16)
        if(!isClose(a.arrayof[i], b.arrayof[i], 1e-5f, 1e-5f))
            return false;

    return true;
}

private void requireOrthonormal(in Matrix4x4f view)
{
    const x = Vector3f(view.a11, view.a12, view.a13);
    const y = Vector3f(view.a21, view.a22, view.a23);

    assert(isClose(x.length, 1, 1e-5f, 1e-5f));
    assert(isClose(y.length, 1, 1e-5f, 1e-5f));
    assert(isClose(dot(x, y), 0, 1e-5f, 1e-5f));
}

unittest
{
    const eye = Vector3f(3, 4, 5);
    const target = Vector3f(1, 2, 0);
    const camera = FlyCamera.lookingAt(eye, target);

    assert(sameView(camera.view, cameraView(eye, target, Vector3f(0, 1, 0))));
}

unittest
{
    auto camera = FlyCamera.lookingAt(Vector3f(3, 4, 5), Vector3f(1, 2, 0));
    camera.rollBy(0.7f);

    const restored = FlyCamera.fromView(camera.view);

    assert(sameView(restored.view, camera.view));
    assert(isClose(restored.position.x, 3, 1e-4f, 1e-4f));
    assert(isClose(restored.position.y, 4, 1e-4f, 1e-4f));
    assert(isClose(restored.position.z, 5, 1e-4f, 1e-4f));
}

unittest
{
    // Looking straight up and rolled must survive a view round trip
    auto camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 1, 0));
    camera.rollBy(0.7f);

    const restored = FlyCamera.fromView(camera.view);

    assert(sameView(restored.view, camera.view));
    requireOrthonormal(camera.view);
}

unittest
{
    auto camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 0, -1));

    // Right turns towards +X, down lowers the view
    camera.look(100, 0);
    assert(camera.forward.x > 0);

    camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 0, -1));
    camera.look(0, 100);
    assert(camera.forward.y < 0);

    // A quarter turn of the mouse reaches the zenith without breaking the view
    camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 0, -1));
    camera.look(0, -degtorad(90.0f) / 0.003f);
    assert(camera.forward.y > 0.999f);
    requireOrthonormal(camera.view);

    // At the zenith the screen axes take over: the turn keeps the camera up
    const zenithUp = camera.up;
    camera.look(100, 0);
    assert(isClose(camera.up.x, zenithUp.x, 1e-4f, 1e-4f));
    assert(isClose(camera.up.y, zenithUp.y, 1e-4f, 1e-4f));
    assert(isClose(camera.up.z, zenithUp.z, 1e-4f, 1e-4f));
    requireOrthonormal(camera.view);

    camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 0, -1));
    camera.look(0, degtorad(90.0f) / 0.003f);
    assert(camera.forward.y < -0.999f);
    requireOrthonormal(camera.view);
}

unittest
{
    auto camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 0, -1));

    camera.move(Vector3f(0, 0, 1), 2);
    assert(isClose(camera.position.z, -2, 1e-4f, 1e-4f));

    camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 0, -1));
    camera.move(Vector3f(1, 0, 1), 2);
    assert(isClose(camera.position.length, 2, 1e-4f, 1e-4f));
}

unittest
{
    // With a roll the horizontal drag turns around the screen vertical, as A/D do
    auto camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 0, -1));
    camera.rollBy(0.6f);

    const up = camera.up;
    const right = camera.right;

    camera.look(100, 0);

    assert(isClose(camera.up.x, up.x, 1e-4f, 1e-4f));
    assert(isClose(camera.up.y, up.y, 1e-4f, 1e-4f));
    assert(isClose(camera.up.z, up.z, 1e-4f, 1e-4f));
    assert(dot(camera.forward, right) > 0);
    requireOrthonormal(camera.view);
}

unittest
{
    auto camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 0, -1));

    camera.pan(2, 1);
    assert(isClose(camera.position.x, 2, 1e-4f, 1e-4f));
    assert(isClose(camera.position.y, 1, 1e-4f, 1e-4f));

    // After a quarter turn the pan follows the new screen axes
    camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(1, 0, 0));
    camera.pan(2, 0);
    assert(isClose(camera.position.z, 2, 1e-4f, 1e-4f));
}

unittest
{
    auto camera = FlyCamera.lookingAt(Vector3f(0, 0, 0), Vector3f(0, 1, 0));
    camera.rollBy(0.7f);
    assert(camera.up.z > 0);

    camera.resetRoll();
    assert(isClose(camera.up.y, 0, 1e-4f, 1e-4f));
    assert(isClose(camera.up.z, 1, 1e-4f, 1e-4f));
    assert(camera.forward.y > 0.999f);
}

unittest
{
    FlyCamera camera;

    camera.zoom(1);
    assert(camera.fov < 45);

    camera.zoom(-1);
    assert(isClose(camera.fov, 45, 1e-4f, 1e-4f));

    camera.zoom(1000);
    assert(camera.fov == minFov);

    camera.zoom(-1000);
    assert(camera.fov == maxFov);
}
