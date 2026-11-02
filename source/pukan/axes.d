module pukan.axes;

import dlib.math: Vector3f, cross, dot;
import std.math: abs, cos, sin;

/// One of the coordinate axes, for a direction that is fixed for a whole scene.
///
/// Which axis points up is a property of the game world, not of the code: a character only
/// turns around that axis while it walks on the ground. Deliberately has no base type, so
/// that mixing an axis into arithmetic by accident does not compile.
enum Axis
{
    x,
    y,
    z,
}

/// Unit vector along the axis.
Vector3f axisVector(Axis axis)
{
    final switch(axis)
    {
        case Axis.x:
            return Vector3f(1, 0, 0);
        case Axis.y:
            return Vector3f(0, 1, 0);
        case Axis.z:
            return Vector3f(0, 0, 1);
    }
}

/// Rotates `v` around the axis by `angle` radians, counter-clockwise seen from its tip.
Vector3f rotateAround(Vector3f v, Axis axis, float angle)
{
    const k = axis.axisVector();
    const c = cos(angle);
    const s = sin(angle);

    return v * c + cross(k, v) * s + k * dot(k, v) * (1 - c);
}

/// The direction that reads as forward at a zero turn: the axis that follows the up axis
/// in the x, y, z cycle.
Vector3f axisForward(Axis up)
{
    final switch(up)
    {
        case Axis.x:
            return Vector3f(0, 1, 0);
        case Axis.y:
            return Vector3f(0, 0, 1);
        case Axis.z:
            return Vector3f(1, 0, 0);
    }
}

/// The coordinate axis `direction` points along most.
Axis dominantAxis(Vector3f direction)
{
    const x = abs(direction.x);
    const y = abs(direction.y);
    const z = abs(direction.z);

    if(x >= y && x >= z)
        return Axis.x;

    return y >= z ? Axis.y : Axis.z;
}

/// Drops the component of `v` along the axis, leaving what lies in the ground plane.
Vector3f onPlane(Axis up, Vector3f v)
{
    const normal = up.axisVector();

    return v - normal * dot(v, normal);
}

/// The two components of `v` that span the plane the axis leaves free, in x, y, z order.
float[2] planeComponents(Axis up, Vector3f v)
{
    final switch(up)
    {
        case Axis.x:
            return [v.y, v.z];
        case Axis.y:
            return [v.x, v.z];
        case Axis.z:
            return [v.x, v.y];
    }
}

unittest
{
    enum quarter = 1.5707964f;

    // Around Y, +Z goes to +X
    const turned = Vector3f(0, 0, 1).rotateAround(Axis.y, quarter);
    assert((turned - Vector3f(1, 0, 0)).length < 1e-5);

    // The forward direction at a zero turn is the axis after up
    assert(Axis.y.axisForward == Vector3f(0, 0, 1));
    assert(Axis.z.axisForward == Vector3f(1, 0, 0));

    // The up component is not part of the plane
    const plane = Axis.y.planeComponents(Vector3f(1, 5, 2));
    assert(plane[0] == 1 && plane[1] == 2);

    assert(Vector3f(0.1f, -3, 0.2f).dominantAxis == Axis.y);
}