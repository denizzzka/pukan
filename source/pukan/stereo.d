module pukan.stereo;

import dlib.math: Matrix4x4f, Vector3f, Vector4f, cross, frustumMatrix, lookAtMatrix;
import pukan.vulkan.bindings: VkExtent2D;
import std.math: PI, abs, tan;

struct StereoView
{
    Matrix4x4f view;
    Matrix4x4f proj;
}

/// Parallel stereo: left view for the left half.
/// Cross-eyed viewing needs the halves swapped.
StereoView[2] makeStereoViews(
    Vector3f eye,
    Vector3f target,
    Vector3f up,
    float fovY,
    VkExtent2D eyeExtent,
    float near,
    float far,
    float eyeSeparation,
)
{
    const forward = (target - eye).normalized;
    const right = cross(forward, up).normalized;
    const convergenceDistance = (target - eye).length;
    const aspect = cast(float) eyeExtent.width / eyeExtent.height;
    const top = near * tan(cast(float)(PI * fovY / 360.0));
    const bottom = -top;
    const halfWidth = top * aspect;

    StereoView[2] ret;

    foreach(eyeIdx; 0 .. 2)
    {
        const offset = (eyeIdx == 0 ? -0.5f : 0.5f) * eyeSeparation;
        const eyePos = eye + right * offset;
        const shift = -offset * near / convergenceDistance;

        ret[eyeIdx].view = lookAtMatrix(eyePos, eyePos + forward, up);
        ret[eyeIdx].proj = frustumMatrix(
            -halfWidth + shift,
            halfWidth + shift,
            bottom,
            top,
            near,
            far,
        );
    }

    return ret;
}

unittest
{
    auto eye = Vector3f(0, -0.2, -0.8);
    auto target = Vector3f(0, 0, 0);
    VkExtent2D extent = { width: 320, height: 640 };

    auto views = makeStereoViews(
        eye,
        target,
        Vector3f(0, 1, 0),
        45.0f,
        extent,
        0.1f,
        10.0f,
        0.06f,
    );

    static float project(Vector3f p, StereoView view)
    {
        auto transl = view.proj * view.view;
        // dlib's Vector * Matrix is the column-vector product used by the shader
        auto clip = Vector4f(p.x, p.y, p.z, 1.0f) * transl;

        return clip.x / clip.w;
    }

    const dir = (target - eye).normalized;
    auto near = eye + dir * 0.4f;
    auto far = eye + dir * 1.2f;

    const targetL = project(target, views[0]);
    const targetR = project(target, views[1]);
    const nearL = project(near, views[0]);
    const nearR = project(near, views[1]);
    const farL = project(far, views[0]);
    const farR = project(far, views[1]);

    assert(abs(targetL) < 1e-4f);
    assert(abs(targetR) < 1e-4f);
    assert(nearL > 0 && nearR < 0);
    assert(farL < 0 && farR > 0);
}
