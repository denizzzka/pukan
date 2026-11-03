module pukan.motion_matching.transform;

import dlib.math: Vector3f;
import pukan.graphics.g3d.axes: Axis, axisForward, rotateAround;
import std.math: PI;

/// Position and heading of a character, or of the root bone of a clip.
///
/// Only movement over the ground is described: the heading is a single angle around the up
/// axis, which the scene owns.
struct Transform
{
    Vector3f translation;
    /// Radians around the up axis; zero looks along `Axis.axisForward`.
    float yaw;

    static Transform identity()
    {
        return Transform(Vector3f(0, 0, 0), 0);
    }

    /// Turns a point of the local space into the world space.
    Vector3f apply(Axis up, Vector3f point) const
    {
        return rotate(up, point) + translation;
    }

    /// Turns a world point into the local space.
    Vector3f applyInverse(Axis up, Vector3f point) const
    {
        return rotateInverse(up, point - translation);
    }

    Vector3f rotate(Axis up, Vector3f direction) const
    {
        return direction.rotateAround(up, yaw);
    }

    Vector3f rotateInverse(Axis up, Vector3f direction) const
    {
        return direction.rotateAround(up, -yaw);
    }

    Vector3f forward(Axis up) const
    {
        return rotate(up, up.axisForward);
    }

    /// Interpolates position linearly and heading along the shorter arc;
    /// `t` outside [0, 1] extrapolates.
    static Transform lerp(Transform a, Transform b, float t)
    {
        return Transform(
            a.translation + (b.translation - a.translation) * t,
            a.yaw + wrapAngle(b.yaw - a.yaw) * t,
        );
    }
}

private enum float pi = 3.14159265f;

/// Brings an angle into (-pi, pi].
float wrapAngle(float angle)
{
    angle %= 2 * pi;

    if(angle > pi)
        angle -= 2 * pi;
    else if(angle <= -pi)
        angle += 2 * pi;

    return angle;
}

unittest
{
    import std.math: abs;

    enum up = Axis.y;

    const t = Transform(Vector3f(3, 0, 0), PI / 2);

    // A quarter turn sends +Z to +X
    const p = t.rotate(up, Vector3f(0, 0, 1));
    assert((p - Vector3f(1, 0, 0)).length < 1e-5);
    assert((t.applyInverse(up, t.apply(up, Vector3f(1, 2, 3))) - Vector3f(1, 2, 3)).length < 1e-5);

    assert(wrapAngle(3 * PI / 2) < 0);
    assert(wrapAngle(cast(float) PI) == cast(float) PI);
}

unittest
{
    import std.math: abs;

    const a = Transform(Vector3f(0, 0, 0), 0.1);
    const b = Transform(Vector3f(10, 0, 0), 0.3);

    const half = Transform.lerp(a, b, 0.5);

    assert(half.translation.x == 5);
    assert(abs(half.yaw - 0.2) < 1e-6);

    // Heading takes the short way around: 0.1 -> -0.1 is a -0.2 step, not 6.1
    const c = Transform(Vector3f(0, 0, 0), -0.1);
    assert(abs(Transform.lerp(a, c, 0.5).yaw) < 1e-6);
}
