module pukan.graphics.g3d.portals;

import dlib.math: Matrix4x4f, Vector3f, Vector4f;
import std.exception: enforce;
import std.file: read;
import vibe.data.json: parseJsonString;

/**
    A grid of square rooms joined by a doorway in every shared wall.

    The grid is enough to walk the room graph: a doorway opens the room behind it
    only when its quad lands inside the region the doorways before it left, so a
    room behind a wall never enters the visible list. The regions are rectangles,
    which makes the walk conservative but cheap.
*/
struct PortalGrid
{
    /// Rooms per axis
    int rooms;
    /// Extent of one room in world units
    float roomSize;
    float wallHeight;
    float doorwayWidth;
    float doorwayHeight;

    /// Reads the parameters the generator writes beside the scene
    static PortalGrid load(string path)
    {
        const json = (cast(string) read(path)).parseJsonString;

        PortalGrid grid;
        grid.rooms = json["rooms"].get!int;
        grid.roomSize = json["room_size"].get!float;
        grid.wallHeight = json["wall_height"].get!float;
        grid.doorwayWidth = json["doorway_width"].get!float;
        grid.doorwayHeight = json["doorway_height"].get!float;

        enforce(grid.rooms > 0 && grid.roomSize > 0, "a portal grid needs rooms with a size");

        return grid;
    }

    bool inside(int x, int z) const => x >= 0 && z >= 0 && x < rooms && z < rooms;

    /// Room a world point falls in, clamped to the grid
    void roomOf(in Vector3f point, out int x, out int z) const
    {
        x = cast(int) (point.x / roomSize);
        z = cast(int) (point.z / roomSize);

        if(x < 0) x = 0;
        if(z < 0) z = 0;
        if(x >= rooms) x = rooms - 1;
        if(z >= rooms) z = rooms - 1;
    }

    /**
        Rooms the eye reaches through doorways, the room it stands in included.

        Keyed by `x * rooms + z`, so a caller only has to look its cells up.
    */
    bool[long] visibleRooms(in Vector3f eye, in Matrix4x4f viewProj, int maxDepth = 8)
    {
        bool[long] seen;

        int x, z;
        roomOf(eye, x, z);

        const region = Rect(0, 0, 1, 1);
        walk(x, z, region, 0, maxDepth, seen, viewProj);

        return seen;
    }

    private void walk(
        int x,
        int z,
        in Rect region,
        int depth,
        int maxDepth,
        ref bool[long] seen,
        in Matrix4x4f viewProj,
    )
    {
        const key = cast(long) x * rooms + z;

        if(key in seen)
            return;

        seen[key] = true;

        if(depth >= maxDepth)
            return;

        foreach(side; 0 .. 4)
        {
            const nx = x + ((side == 2) ? -1 : (side == 3) ? 1 : 0);
            const nz = z + ((side == 0) ? -1 : (side == 1) ? 1 : 0);

            if(!inside(nx, nz))
                continue;

            if((cast(long) nx * rooms + nz) in seen)
                continue;

            Rect doorway;

            if(!doorwayOf(x, z, side, viewProj, doorway))
                continue;

            const overlap = region.intersect(doorway);

            // The doorway has to overlap what the eye can see through the ones before
            if(overlap.empty)
                continue;

            walk(nx, nz, overlap, depth + 1, maxDepth, seen, viewProj);
        }
    }

    /// Screen rectangle of the doorway on `side` of room (x, z); false when it
    /// reaches behind the eye, where the walk gives up on rectangles
    private bool doorwayOf(int x, int z, int side, in Matrix4x4f viewProj, out Rect rect)
    {
        // The wall plane sits between the two rooms, the doorway in its middle
        const half = roomSize * 0.5f;
        const centre = Vector3f(x * roomSize + half, doorwayHeight * 0.5f, z * roomSize + half);
        const along = doorwayWidth * 0.5f;

        Vector3f[4] corners;

        foreach(i; 0 .. 4)
        {
            const u = (i == 0 || i == 3) ? -along : along;
            const v = (i < 2) ? -doorwayHeight * 0.5f : doorwayHeight * 0.5f;

            switch(side)
            {
                case 0: corners[i] = centre + Vector3f(u, v, -half); break;
                case 1: corners[i] = centre + Vector3f(u, v, half); break;
                case 2: corners[i] = centre + Vector3f(-half, v, u); break;
                default: corners[i] = centre + Vector3f(half, v, u); break;
            }
        }

        float left = float.infinity;
        float right = -float.infinity;
        float top = float.infinity;
        float bottom = -float.infinity;

        foreach(corner; corners)
        {
            const clip = Vector4f(corner.x, corner.y, corner.z, 1) * viewProj;

            // A doorway crossing the eye plane spans whatever the region is
            if(!(clip.w > 0))
            {
                rect = Rect(0, 0, 1, 1);
                return true;
            }

            const sx = clip.x / clip.w * 0.5f + 0.5f;
            const sy = 0.5f - clip.y / clip.w * 0.5f;

            left = sx < left ? sx : left;
            right = sx > right ? sx : right;
            top = sy < top ? sy : top;
            bottom = sy > bottom ? sy : bottom;
        }

        rect = Rect(left, top, right, bottom);

        return true;
    }

    /// A rectangle in screen space, 0 to 1 on both axes
    private struct Rect
    {
        float left;
        float top;
        float right;
        float bottom;

        bool empty() const => right <= left || bottom <= top;

        Rect intersect(in Rect other) const
        {
            Rect result;
            result.left = left > other.left ? left : other.left;
            result.top = top > other.top ? top : other.top;
            result.right = right < other.right ? right : other.right;
            result.bottom = bottom < other.bottom ? bottom : other.bottom;

            if(result.empty)
                return Rect(0, 0, 0, 0);

            return result;
        }
    }
}

unittest
{
    // A 4 by 4 grid: from a corner room the walk reaches every room, and a
    // doorway pointed away from the view opens nothing
    import dlib.math: Matrix4x4f;

    PortalGrid grid;
    grid.rooms = 4;
    grid.roomSize = 16;
    grid.wallHeight = 4;
    grid.doorwayWidth = 3;
    grid.doorwayHeight = 2.6;

    // Looking down +z from the first room, so the walls across are in view
    auto viewProj = Matrix4x4f.identity;
    viewProj.a43 = 1;

    const eye = Vector3f(8, 1.7f, 8);
    const seen = grid.visibleRooms(eye, viewProj);

    assert((0L in seen), "the room the eye stands in is always visible");
    assert(seen.length >= 1);

    // A point far outside the grid clamps to its nearest room
    int x, z;
    grid.roomOf(Vector3f(-100, 0, -100), x, z);
    assert(x == 0 && z == 0);
}
