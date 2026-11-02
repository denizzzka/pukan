module pukan.motion_matching.transform;

import dlib.math: Vector3f;
import std.math: PI, abs, cos, sin;

/// Position and heading of a character, or of the root bone of a clip.
/// Only movement over the ground is described: the up axis is Y.
struct Transform
{
    Vector3f translation;
    /// Radians around the up axis; zero looks along +Z.
    float yaw;

    static Transform identity()
    {
        return Transform(Vector3f(0, 0, 0), 0);
    }

    /// Turns a point of the local space into the world space.
    Vector3f apply(Vector3f point) const
    {
        return rotate(point) + translation;
    }

    /// Turns a world point into the local space.
    Vector3f applyInverse(Vector3f point) const
    {
        return rotateInverse(point - translation);
    }

    Vector3f rotate(Vector3f direction) const
    {
        return rotateAroundUp(direction, yaw);
    }

    Vector3f rotateInverse(Vector3f direction) const
    {
        return rotateAroundUp(direction, -yaw);
    }

    Vector3f forward() const
    {
        return Vector3f(sin(yaw), 0, cos(yaw));
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

/// Rotates around the up axis, the one direction the ground leaves free.
Vector3f rotateAroundUp(Vector3f v, float angle)
{
    const c = cos(angle);
    const s = sin(angle);

    return Vector3f(
        v.x * c + v.z * s,
        v.y,
        -v.x * s + v.z * c,
    );
}

unittest
{
    const t = Transform(Vector3f(3, 0, 0), PI / 2);

    // A quarter turn sends +Z to +X
    const p = t.rotate(Vector3f(0, 0, 1));
    assert((p - Vector3f(1, 0, 0)).length < 1e-5);
    assert((t.applyInverse(t.apply(Vector3f(1, 2, 3))) - Vector3f(1, 2, 3)).length < 1e-5);

    assert(wrapAngle(3 * PI / 2) < 0);
    assert(wrapAngle(cast(float) PI) == cast(float) PI);
}

unittest
{
    const a = Transform(Vector3f(0, 0, 0), 0.1);
    const b = Transform(Vector3f(10, 0, 0), 0.3);

    const half = Transform.lerp(a, b, 0.5);

    assert(half.translation.x == 5);
    assert(abs(half.yaw - 0.2) < 1e-6);

    // Heading takes the short way around: 0.1 -> -0.1 is a -0.2 step, not 6.1
    const c = Transform(Vector3f(0, 0, 0), -0.1);
    assert(abs(Transform.lerp(a, c, 0.5).yaw) < 1e-6);
}
