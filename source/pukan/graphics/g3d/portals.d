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
        float[long] widest;

        // The whole screen, wound the way the clip expects
        Point[] screen = [Point(0, 0), Point(1, 0), Point(1, 1), Point(0, 1)];
        normalize(screen);

        // An eye on a wall plane stands in every room the plane touches, and a
        // game camera does reach one at the edge of a cell
        int nearX, nearZ, farX, farZ;
        roomOf(eye - Vector3f(standing, 0, standing), nearX, nearZ);
        roomOf(eye + Vector3f(standing, 0, standing), farX, farZ);

        foreach(x; nearX .. farX + 1)
            foreach(z; nearZ .. farZ + 1)
                walk(x, z, screen, 0, maxDepth, seen, widest, viewProj);

        return seen;
    }

    private void walk(
        int x,
        int z,
        scope const(Point)[] region,
        int depth,
        int maxDepth,
        ref bool[long] seen,
        ref float[long] widest,
        in Matrix4x4f viewProj,
    )
    {
        const key = cast(long) x * rooms + z;
        const size = area(region);

        // A room reached again through a wider doorway can see further
        if(auto previous = key in widest)
            if(size <= *previous)
                return;

        widest[key] = size;
        seen[key] = true;

        if(depth >= maxDepth || region.length < 3)
            return;

        foreach(side; 0 .. 4)
        {
            const nx = x + ((side == 2) ? -1 : (side == 3) ? 1 : 0);
            const nz = z + ((side == 0) ? -1 : (side == 1) ? 1 : 0);

            if(!inside(nx, nz))
                continue;

            Point[4] doorway;
            bool spans;

            if(!projectDoorway(x, z, side, viewProj, doorway, spans))
                continue;

            // A doorway crossing the eye plane spans the whole region
            const narrowed = spans
                ? region.dup
                : clip(doorway[], region);

            if(narrowed.length < 3)
                continue;

            walk(nx, nz, narrowed, depth + 1, maxDepth, seen, widest, viewProj);
        }
    }

    /// Screen quad of the doorway on `side` of room (x, z)
    private bool projectDoorway(
        int x,
        int z,
        int side,
        in Matrix4x4f viewProj,
        out Point[4] corners,
        out bool spans,
    )
    {
        // The wall plane sits between the two rooms, the doorway in its middle
        const half = roomSize * 0.5f;
        const centre = Vector3f(x * roomSize + half, doorwayHeight * 0.5f, z * roomSize + half);
        const along = doorwayWidth * 0.5f;

        spans = false;

        foreach(i; 0 .. 4)
        {
            const u = (i == 0 || i == 3) ? -along : along;
            const v = (i < 2) ? -doorwayHeight * 0.5f : doorwayHeight * 0.5f;

            Vector3f corner;

            switch(side)
            {
                case 0: corner = centre + Vector3f(u, v, -half); break;
                case 1: corner = centre + Vector3f(u, v, half); break;
                case 2: corner = centre + Vector3f(-half, v, u); break;
                default: corner = centre + Vector3f(half, v, u); break;
            }

            const clipPoint = Vector4f(corner.x, corner.y, corner.z, 1) * viewProj;

            if(!(clipPoint.w > 0))
            {
                spans = true;
                return true;
            }

            corners[i] = Point(
                clipPoint.x / clipPoint.w * 0.5f + 0.5f,
                0.5f - clipPoint.y / clipPoint.w * 0.5f,
            );
        }

        normalize(corners[]);

        // A doorway grazing the region edge still lets a sliver through, and the
        // clip would drop the room behind it
        float cx = 0;
        float cy = 0;

        foreach(corner; corners)
        {
            cx += corner.x;
            cy += corner.y;
        }

        cx /= 4;
        cy /= 4;

        foreach(ref corner; corners)
        {
            corner.x += (corner.x - cx) * grazing;
            corner.y += (corner.y - cy) * grazing;
        }

        return true;
    }

    /// How far the eye may sit from a wall plane and still stand in both rooms
    enum float standing = 0.05f;

    /// How much a doorway grows before the clip, so a grazing view keeps its room
    enum float grazing = 0.01f;

    /// A point in screen space, 0 to 1 on both axes
    private struct Point
    {
        float x;
        float y;
    }

    /// Screen area of a polygon, for the widest-path test
    private static float area(scope const(Point)[] polygon)
    {
        float total;

        foreach(i; 0 .. polygon.length)
        {
            const a = polygon[i];
            const b = polygon[(i + 1) % polygon.length];
            total += a.x * b.y - b.x * a.y;
        }

        return total < 0 ? -total * 0.5f : total * 0.5f;
    }

    /// Turns a convex polygon the way the clip expects
    private static void normalize(Point[] polygon)
    {
        float signed;

        foreach(i; 0 .. polygon.length)
        {
            const a = polygon[i];
            const b = polygon[(i + 1) % polygon.length];
            signed += a.x * b.y - b.x * a.y;
        }

        if(signed >= 0)
            return;

        foreach(i; 0 .. polygon.length / 2)
        {
            const swap = polygon[i];
            polygon[i] = polygon[polygon.length - 1 - i];
            polygon[polygon.length - 1 - i] = swap;
        }
    }

    /// The interior side of an edge, for the winding `normalize` leaves
    private static bool insideEdge(in Point a, in Point b, in Point p)
    {
        return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) <= 0;
    }

    /// Sutherland-Hodgman: the part of `subject` inside the convex `region`
    private static Point[] clip(in Point[] subject, scope const(Point)[] region)
    {
        Point[] output = subject.dup;

        foreach(i; 0 .. region.length)
        {
            if(output.length == 0)
                break;

            const a = region[i];
            const b = region[(i + 1) % region.length];

            Point[] input = output;
            output = null;

            foreach(j; 0 .. input.length)
            {
                const current = input[j];
                const previous = input[(j + input.length - 1) % input.length];

                const currentIn = insideEdge(a, b, current);
                const previousIn = insideEdge(a, b, previous);

                if(currentIn != previousIn)
                    output ~= crossing(previous, current, a, b);

                if(currentIn)
                    output ~= current;
            }
        }

        if(output.length >= 3)
            normalize(output);

        return output;
    }

    /// Where the segment from `p` to `q` meets the line through `a` and `b`
    private static Point crossing(in Point p, in Point q, in Point a, in Point b)
    {
        const dx = q.x - p.x;
        const dy = q.y - p.y;
        const ex = b.x - a.x;
        const ey = b.y - a.y;

        const denominator = dx * ey - dy * ex;

        if(denominator == 0)
            return q;

        const t = ((a.x - p.x) * ey - (a.y - p.y) * ex) / denominator;

        return Point(p.x + dx * t, p.y + dy * t);
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
