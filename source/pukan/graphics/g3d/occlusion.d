module pukan.graphics.g3d.occlusion;

import dlib.math: Matrix4x4f, Vector3f, Vector4f;
import pukan.graphics.common.misc: Boxf, hasBounds;
import std.algorithm: max, min;
import std.math: isNaN;

/**
    A coarse depth grid the CPU tests boxes against.

    The samples come from a real depth buffer, one nearest depth per screen
    block, so a sample holds a surface that really covers it. A sample nothing
    covers stays NaN, and a box counts as hidden only when every sample of its
    screen rectangle lies behind a surface, which keeps the test conservative.
*/
struct DepthRaster
{
    private int width;
    private int height;
    /// Nearest surface depth per sample, in clip z over w; NaN marks a sample
    /// nothing covers
    private float[] depths;

    /// Depth a box has to beat to count as hidden, in the same units
    float bias = 0.00002f;
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

    /// The samples, to be filled from a real depth buffer
    float[] samples() => depths;

    /// Fills the grid from depths already measured, nearest first
    void load(scope const(float)[] samples)
    in(samples.length == depths.length)
    {
        depths[] = samples[];
        rejected = 0;
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

            const depth = clip[i].z / clip[i].w;
            nearest = nearest > depth ? depth : nearest;
        }

        const rect = screenRect(clip, width, height);

        if(rect.empty)
            return false;

        const limit = nearest - bias;

        foreach(y; rect.top .. rect.bottom + 1)
            foreach(x; rect.left .. rect.right + 1)
            {
                const depth = depths[y * width + x];

                // One sample without a surface leaves the box visible
                if(depth.isNaN || depth >= limit)
                    return false;
            }

        ++rejected;

        return true;
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
    // A wall at a fixed depth covers its rectangle; boxes behind it hide
    auto viewProj = Matrix4x4f.identity;

    DepthRaster raster;
    raster.reset(32, 32);

    // Every sample holds a surface at ndc 0.5, and the left column is open sky
    float[] wall;
    wall.length = 32 * 32;
    wall[] = 0.5f;

    foreach(y; 0 .. 32)
        wall[y * 32] = float.nan;

    raster.load(wall);

    const behind = Boxf(Vector3f(-0.5f, -0.5f, 0.8f), Vector3f(0.5f, 0.5f, 0.9f));
    const inFront = Boxf(Vector3f(-0.5f, -0.5f, 0.2f), Vector3f(0.5f, 0.5f, 0.3f));

    assert(raster.covered() == 32 * 31);
    assert(raster.hidden(behind, viewProj), "a box behind the wall is hidden");
    assert(raster.rejected == 1);
    assert(!raster.hidden(inFront, viewProj), "a box in front of the wall shows");

    // A box whose rectangle reaches the open column stays visible
    const beside = Boxf(Vector3f(-20, -0.5f, 0.8f), Vector3f(20, 0.5f, 0.9f));
    assert(!raster.hidden(beside, viewProj));

    // A box that reaches behind the camera is left alone
    const straddling = Boxf(Vector3f(-0.5f, -0.5f, -3), Vector3f(0.5f, 0.5f, 0.9f));
    assert(!raster.hidden(straddling, viewProj));
}
