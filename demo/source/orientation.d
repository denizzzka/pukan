module orientation;

import dlib.math: Vector2f, Vector3f, cross;
import pukan.graphics.g3d.scene: Vertex;

/// Atlas with one labelled tile per face, in the order of `orientationFaces`
enum orientationAtlasPath = "demo/assets/orientation.png";

/// Layout of `orientationAtlasPath`
enum orientationColumns = 3;
enum orientationRows = 2;
enum orientationAtlasWidth = 768;
enum orientationAtlasHeight = 512;

/// One labelled face of the orientation cube: outward normal, its up axis and
/// the tile it samples
struct OrientationFace
{
    Vector3f normal;
    Vector3f up;
    uint column;
    uint row;
}

immutable OrientationFace[] orientationFaces = [
    OrientationFace(Vector3f(0, 0, 1), Vector3f(0, 1, 0), 0, 0), // front
    OrientationFace(Vector3f(0, 0, -1), Vector3f(0, 1, 0), 1, 0), // back
    OrientationFace(Vector3f(-1, 0, 0), Vector3f(0, 1, 0), 2, 0), // left
    OrientationFace(Vector3f(1, 0, 0), Vector3f(0, 1, 0), 0, 1), // right
    OrientationFace(Vector3f(0, 1, 0), Vector3f(0, 0, 1), 1, 1), // top
    OrientationFace(Vector3f(0, -1, 0), Vector3f(0, 0, -1), 2, 1), // bottom
];

/// Labelled cube with one atlas tile per face, readable from outside
void createOrientationCube(out Vertex[] vertices, out ushort[] indices, float half)
{
    foreach(face; orientationFaces)
    {
        // Right as seen from outside, so the label reads correctly
        const right = cross(face.up, face.normal);
        const center = face.normal * half;
        const white = Vector3f(1, 1, 1);

        // Inset by a texel so linear filtering cannot blend into a neighbour
        const u0 = cast(float) face.column / orientationColumns + 1.0f / orientationAtlasWidth;
        const u1 = cast(float) (face.column + 1) / orientationColumns - 1.0f / orientationAtlasWidth;
        const v0 = cast(float) face.row / orientationRows + 1.0f / orientationAtlasHeight;
        const v1 = cast(float) (face.row + 1) / orientationRows - 1.0f / orientationAtlasHeight;

        const base = cast(ushort) vertices.length;
        vertices ~= [
            Vertex(center - right * half - face.up * half, white, Vector2f(u0, v1)),
            Vertex(center + right * half - face.up * half, white, Vector2f(u1, v1)),
            Vertex(center + right * half + face.up * half, white, Vector2f(u1, v0)),
            Vertex(center - right * half + face.up * half, white, Vector2f(u0, v0)),
        ];
        indices ~= cast(ushort[]) [base + 2, base + 1, base, base, base + 3, base + 2];
    }
}
