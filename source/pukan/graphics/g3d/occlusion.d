module pukan.graphics.g3d.occlusion;

import dlib.math: Matrix4x4f, Vector3f, Vector4f;
import pukan.graphics.common.misc: Boxf, hasBounds;
import std.algorithm: max, min;
import std.math: isNaN;

/**
    A coarse depth grid the CPU rasterizes box occluders into and tests boxes
    against.

    Each occluder box is drawn as its six faces, so a sample holds the depth of
    a surface that really covers it: the near wall of a room, not the far side of
    its volume. A sample no face covers stays NaN, and a box counts as hidden
    only when every sample of its screen rectangle lies behind a surface.
*/
struct DepthRaster
{
    private int width;
    private int height;
    /// Nearest surface depth per sample; NaN marks a sample no occluder covers
    private float[] depths;

    /// Depth a box has to beat to count as hidden, in world units
    float bias = 0.5f;
    /// Boxes the grid hid since the last reset
    size_t rejected;

    this(int columns, int rows)
    {
        reset(columns, rows);
    }

    /// Sample depth, for tests and budgets; NaN when no occluder covers it
    float depthAt(int x, int y) const => depths[y * width + x];

    void reset(int columns, int rows)
    {
        if(columns != width || rows != height)
        {
            width = columns;
            height = rows;
            depths.length = columns * rows;
        }

        depths[] = float.nan;
        rejected = 0;
    }

    /// Samples some occluder covers
    size_t covered() const
    {
        size_t total;

        foreach(depth; depths)
            if(!depth.isNaN)
                ++total;

        return total;
    }

    /// Rasterizes the box as six faces into the grid
    void add(in Boxf box, in Matrix4x4f mvp)
    {
        if(!hasBounds(box))
            return;

        Vector4f[8] clip;

        foreach(i; 0 .. 8)
        {
            const corner = Vector3f(
                (i & 1) ? box.max.x : box.min.x,
                (i & 2) ? box.max.y : box.min.y,
                (i & 4) ? box.max.z : box.min.z,
            );
            clip[i] = Vector4f(corner.x, corner.y, corner.z, 1) * mvp;

            // A box that reaches behind the camera covers nothing it promises
            if(!(clip[i].w > 0))
                return;
        }

        // Six faces, each two triangles, as corner pairs of the box
        static immutable ubyte[36] faces = [
            0, 2, 6, 0, 6, 4,
            1, 5, 7, 1, 7, 3,
            0, 4, 5, 0, 5, 1,
            2, 3, 7, 2, 7, 6,
            0, 1, 3, 0, 3, 2,
            4, 6, 7, 4, 7, 5,
        ];

        foreach(i; 0 .. faces.length / 3)
            triangle(clip[faces[i * 3]], clip[faces[i * 3 + 1]], clip[faces[i * 3 + 2]]);
    }

    /// Whether the box sits behind what the grid already holds
    bool hidden(in Boxf box, in Matrix4x4f mvp)
    {
        if(!hasBounds(box))
            return false;

        Vector4f[8] clip;
        float nearest = float.infinity;

        foreach(i; 0 .. 8)
        {
            const corner = Vector3f(
                (i & 1) ? box.max.x : box.min.x,
                (i & 2) ? box.max.y : box.min.y,
                (i & 4) ? box.max.z : box.min.z,
            );
            clip[i] = Vector4f(corner.x, corner.y, corner.z, 1) * mvp;

            // One corner behind the camera leaves the box visible
            if(!(clip[i].w > 0))
                return false;

            nearest = nearest > clip[i].w ? clip[i].w : nearest;
        }

        const rect = screenRect(clip, width, height);

        if(rect.empty)
            return false;

        const limit = nearest + bias;

        foreach(y; rect.top .. rect.bottom + 1)
            foreach(x; rect.left .. rect.right + 1)
            {
                const depth = depths[y * width + x];

                // One sample without a surface leaves the box visible
                if(depth.isNaN || depth > limit)
                    return false;
            }

        ++rejected;

        return true;
    }

    /// Draws one clip-space triangle, keeping the nearest depth per sample
    private void triangle(in Vector4f start, in Vector4f middle, in Vector4f end)
    {
        Vector4f a = start;
        Vector4f b = middle;
        Vector4f c = end;

        // Winding does not matter to a depth grid, so the corners are ordered
        // until the signed area is positive
        auto area = (screenX(b) - screenX(a)) * (screenY(c) - screenY(a))
            - (screenY(b) - screenY(a)) * (screenX(c) - screenX(a));

        if(area == 0)
            return;

        if(area < 0)
        {
            Vector4f swap = b;
            b = c;
            c = swap;
            area = -area;
        }

        const ax = screenX(a), ay = screenY(a);
        const bx = screenX(b), by = screenY(b);
        const cx = screenX(c), cy = screenY(c);

        const left = clampIndex(min(ax, min(bx, cx)), width);
        const right = clampIndex(max(ax, max(bx, cx)), width);
        const top = clampIndex(min(ay, min(by, cy)), height);
        const bottom = clampIndex(max(ay, max(by, cy)), height);

        if(left > right || top > bottom)
            return;

        foreach(y; top .. bottom + 1)
            foreach(x; left .. right + 1)
            {
                const px = x + 0.5f;
                const py = y + 0.5f;

                const wa = ((bx - px) * (cy - py) - (by - py) * (cx - px)) / area;
                const wb = ((cx - px) * (ay - py) - (cy - py) * (ax - px)) / area;
                const wc = 1.0f - wa - wb;

                if(wa < 0 || wb < 0 || wc < 0)
                    continue;

                // Perspective-correct depth from the corners' clip w
                const depth = 1.0f / (wa / a.w + wb / b.w + wc / c.w);

                ref sample = depths[y * width + x];

                if(sample.isNaN || depth < sample)
                    sample = depth;
            }
    }

    private float screenX(in Vector4f clip) const => (clip.x / clip.w * 0.5f + 0.5f) * width;
    private float screenY(in Vector4f clip) const => (0.5f - clip.y / clip.w * 0.5f) * height;

    private static int clampIndex(float value, int limit)
    {
        const index = cast(int) value;

        if(index < 0)
            return 0;

        return index >= limit ? limit - 1 : index;
    }

    /// Screen rectangle of a clip-space box, clipped to the grid
    private struct Rect
    {
        int left;
        int top;
        int right;
        int bottom;

        bool empty() const => left > right || top > bottom;
    }

    private static Rect screenRect(scope const(Vector4f)[8] clip, int width, int height)
    {
        Rect result;
        result.left = int.max;
        result.top = int.max;
        result.right = int.min;
        result.bottom = int.min;

        foreach(c; clip)
        {
            const ix = cast(int) ((c.x / c.w * 0.5f + 0.5f) * width);
            const iy = cast(int) ((0.5f - c.y / c.w * 0.5f) * height);

            result.left = ix < result.left ? ix : result.left;
            result.top = iy < result.top ? iy : result.top;
            result.right = ix > result.right ? ix : result.right;
            result.bottom = iy > result.bottom ? iy : result.bottom;
        }

        // A rectangle outside the grid covers no sample at all
        if(result.right < 0 || result.bottom < 0 || result.left >= width || result.top >= height)
        {
            result.left = 1;
            result.top = 1;
            result.right = 0;
            result.bottom = 0;

            return result;
        }

        result.left = result.left < 0 ? 0 : result.left;
        result.top = result.top < 0 ? 0 : result.top;
        result.right = result.right >= width ? width - 1 : result.right;
        result.bottom = result.bottom >= height ? height - 1 : result.bottom;

        return result;
    }
}

/// Grid the gather consults, or null when occlusion culling is off
DepthRaster* currentOcclusion;

unittest
{
    // A wall in front covers the rectangles behind it
    auto viewProj = Matrix4x4f.identity;
    viewProj.a43 = 1;

    DepthRaster raster;
    raster.reset(32, 32);

    const wall = Boxf(Vector3f(-4, -2, 2), Vector3f(4, 2, 2.2f));
    const behind = Boxf(Vector3f(-0.5f, -0.5f, 6), Vector3f(0.5f, 0.5f, 7));
    const inFront = Boxf(Vector3f(-0.5f, -0.5f, 0.5f), Vector3f(0.5f, 0.5f, 1));

    raster.add(wall, viewProj);

    assert(raster.covered() > 0);
    assert(raster.hidden(behind, viewProj), "the box behind the wall is hidden");
    assert(raster.rejected == 1);
    assert(!raster.hidden(inFront, viewProj), "a box in front of the wall shows");

    // A box beside the wall stays visible
    const beside = Boxf(Vector3f(20, -0.5f, 6), Vector3f(21, 0.5f, 7));
    assert(!raster.hidden(beside, viewProj));

    // A box that reaches behind the camera is left alone
    const straddling = Boxf(Vector3f(-0.5f, -0.5f, -3), Vector3f(0.5f, 0.5f, 7));
    assert(!raster.hidden(straddling, viewProj));
}
