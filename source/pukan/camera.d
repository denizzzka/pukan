module pukan.camera;

import dlib.math: Matrix4x4f, Vector3f, dot, perspectiveMatrix;

/// Transform of a camera placed at `eye` and looking at `target`
Matrix4x4f cameraTransform(Vector3f eye, Vector3f target, Vector3f up)
{
    import dlib.math: cross;
    import std.math: abs;

    const forward = (target - eye).normalized;
    auto realUp = up;

    // A view parallel to the up axis has no right axis, so any other axis serves
    if(cross(forward, realUp).length < 1e-6f)
        realUp = abs(forward.y) > 0.9f ? Vector3f(0, 0, 1) : Vector3f(0, 1, 0);

    const right = cross(forward, realUp).normalized;
    realUp = cross(right, forward);

    // Rows of the row-vector transform; the Matrix constructor takes them
    // in row-major order
    const float[16] rows = [
        right.x,     realUp.x,     -forward.x, eye.x,
        right.y,     realUp.y,     -forward.y, eye.y,
        right.z,     realUp.z,     -forward.z, eye.z,
        0,           0,            0,          1,
    ];

    return Matrix4x4f(rows[]);
}

/// View matrix of a camera whose -Z axis points at `target`
Matrix4x4f cameraView(Vector3f eye, Vector3f target, Vector3f up)
{
    return cameraTransform(eye, target, up).inverse;
}

/// Perspective projection for Vulkan, whose clip space has Y pointing down,
/// unlike the OpenGL convention that dlib builds
Matrix4x4f vulkanPerspectiveMatrix(float fovY, float aspectRatio, float nearPlane, float farPlane)
{
    auto result = perspectiveMatrix(fovY, aspectRatio, nearPlane, farPlane);
    result.a22 = -result.a22;
    return result;
}

unittest
{
    import dlib.math: lookAtMatrix;
    import std.math: abs;

    const eye = Vector3f(3, 4, -5);
    const target = Vector3f(0, 1, 0);
    const up = Vector3f(0, 1, 0);

    // The inverse of the camera transform matches dlib for a normal view
    const expected = lookAtMatrix(eye, target, up);
    const view = cameraView(eye, target, up);

    foreach(i; 0 .. 16)
        assert(abs(view.arrayof[i] - expected.arrayof[i]) < 1e-5f);

    // A view along the up axis must not assert and still give an orthonormal basis
    const vertical = cameraView(Vector3f(0, 10, 0), Vector3f(0, 0, 0), up);
    const x = Vector3f(vertical.a11, vertical.a12, vertical.a13);
    const y = Vector3f(vertical.a21, vertical.a22, vertical.a23);

    assert(abs(x.length - 1) < 1e-5f);
    assert(abs(y.length - 1) < 1e-5f);
    assert(abs(x.dot(y)) < 1e-5f);
}

unittest
{
    import dlib.math: rotationQuaternion;

    // Approaching the pole must keep the roll instead of snapping to another up
    const worldUp = Vector3f(0, 1, 0);
    const a = Vector3f(0.05f, 1, 0).normalized;
    const b = Vector3f(0.042f, 1, 0).normalized;

    const viewA = cameraTransform(Vector3f(0, 0, 0), a,
        rotationQuaternion(a, 0.7f).rotate(worldUp));
    const viewB = cameraTransform(Vector3f(0, 0, 0), b,
        rotationQuaternion(b, 0.7f).rotate(worldUp));

    const upA = Vector3f(viewA.a12, viewA.a22, viewA.a32);
    const upB = Vector3f(viewB.a12, viewB.a22, viewB.a32);

    assert(upA.dot(upB) > 0.99f);
}
