module pukan.graphics.g3d.portals;

import dlib.math: Matrix4x4f, Vector3f, Vector4f;
import std.exception: enforce;
import std.file: read;
import vibe.data.json: parseJsonString;

/// One doorway: the two rooms it joins and its four world corners
struct RoomPortal
{
    long a;
    long b;
    Vector3f[4] corners;
}

/**
    Doorways read from a level, so a scene can author its own rooms.

    The walk is the same one the grid uses: a doorway opens the room behind it
    only where it overlaps the region the doorways before it left.
*/
struct PortalSet
{
    RoomPortal[] portals;

    /// Key of the room a world point falls in, for a grid of `roomSize` squares
    static long keyOf(in Vector3f point, float roomSize, int rooms)
    {
        int x = cast(int) (point.x / roomSize);
        int z = cast(int) (point.z / roomSize);

        x = x < 0 ? 0 : (x >= rooms ? rooms - 1 : x);
        z = z < 0 ? 0 : (z >= rooms ? rooms - 1 : z);

        return cast(long) x * rooms + z;
    }

    /// Rooms an eye stands in, for an eye on a wall plane more than one
    static long[] startRooms(in Vector3f eye, float roomSize, int rooms)
    {
        long[] result;

        foreach(dx; [-PortalGrid.standing, PortalGrid.standing])
            foreach(dz; [-PortalGrid.standing, PortalGrid.standing])
            {
                const key = keyOf(eye + Vector3f(dx, 0, dz), roomSize, rooms);

                if(result.length == 0 || result[$ - 1] != key)
                    result ~= key;
            }

        return result;
    }

    /// Rooms the eye reaches from `starts`, keyed like `keyOf`
    bool[long] visibleRooms(scope const(long)[] starts, in Matrix4x4f viewProj, int maxDepth = 8)
    {
        bool[long] seen;
        float[long] widest;

        Point[] screen = [Point(0, 0), Point(1, 0), Point(1, 1), Point(0, 1)];
        normalize(screen);

        foreach(start; starts)
            walkPortal(portals, start, screen, 0, maxDepth, seen, widest, viewProj);

        return seen;
    }
}

/**
    A grid of square rooms joined by a doorway in every shared wall.

    The grid derives its doorways, which is what the generated hall needs; a
    level with its own rooms fills a `PortalSet` instead.
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

    /// How far the eye may sit from a wall plane and still stand in both rooms
    enum float standing = 0.05f;

    /// How much a doorway grows before the clip, so a grazing view keeps its room
    enum float grazing = 0.01f;

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

    /// Doorways the grid implies, one per shared wall
    RoomPortal[] portals() const
    {
        RoomPortal[] result;

        foreach(x; 0 .. rooms)
            foreach(z; 0 .. rooms)
                foreach(side; 0 .. 4)
                {
                    const nx = x + ((side == 2) ? -1 : (side == 3) ? 1 : 0);
                    const nz = z + ((side == 0) ? -1 : (side == 1) ? 1 : 0);

                    if(!inside(nx, nz))
                        continue;

                    result ~= RoomPortal(
                        cast(long) x * rooms + z,
                        cast(long) nx * rooms + nz,
                        cornersOf(x, z, side),
                    );
                }

        return result;
    }

    /**
        Rooms the eye reaches through doorways, the room it stands in included.

        Keyed by `x * rooms + z`, so a caller only has to look its cells up.
    */
    bool[long] visibleRooms(in Vector3f eye, in Matrix4x4f viewProj, int maxDepth = 8)
    {
        bool[long] seen;
        float[long] widest;

        Point[] screen = [Point(0, 0), Point(1, 0), Point(1, 1), Point(0, 1)];
        normalize(screen);

        // An eye on a wall plane stands in every room the plane touches
        int nearX, nearZ, farX, farZ;
        roomOf(eye - Vector3f(standing, 0, standing), nearX, nearZ);
        roomOf(eye + Vector3f(standing, 0, standing), farX, farZ);

        const doorways = portals();

        foreach(x; nearX .. farX + 1)
            foreach(z; nearZ .. farZ + 1)
                walkPortal(doorways, cast(long) x * rooms + z, screen, 0, maxDepth,
                    seen, widest, viewProj);

        return seen;
    }

    /// World corners of the doorway on `side` of room (x, z)
    private Vector3f[4] cornersOf(int x, int z, int side) const
    {
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

        return corners;
    }
}

/// Walks the doorways of `room`, narrowing the region at each one
private void walkPortal(
    scope const(RoomPortal)[] portals,
    long room,
    scope const(Point)[] region,
    int depth,
    int maxDepth,
    ref bool[long] seen,
    ref float[long] widest,
    in Matrix4x4f viewProj,
)
{
    const size = area(region);

    // A room reached again through a wider doorway can see further
    if(auto previous = room in widest)
        if(size <= *previous)
            return;

    widest[room] = size;
    seen[room] = true;

    if(depth >= maxDepth || region.length < 3)
        return;

    foreach(portal; portals)
    {
        long next;

        if(portal.a == room)
            next = portal.b;
        else if(portal.b == room)
            next = portal.a;
        else
            continue;

        Point[4] doorway;
        bool spans;

        if(!projectDoorway(portal.corners, viewProj, doorway, spans))
            continue;

        // A doorway crossing the eye plane spans the whole region
        const narrowed = spans ? region.dup : clip(doorway[], region);

        if(narrowed.length < 3)
            continue;

        walkPortal(portals, next, narrowed, depth + 1, maxDepth, seen, widest, viewProj);
    }
}

/// Screen quad of a doorway; `spans` when it reaches behind the eye
private bool projectDoorway(
    in Vector3f[4] corners,
    in Matrix4x4f viewProj,
    out Point[4] projected,
    out bool spans,
)
{
    spans = false;

    foreach(i; 0 .. 4)
    {
        const clipPoint = Vector4f(corners[i].x, corners[i].y, corners[i].z, 1) * viewProj;

        if(!(clipPoint.w > 0))
        {
            spans = true;
            return true;
        }

        projected[i] = Point(
            clipPoint.x / clipPoint.w * 0.5f + 0.5f,
            0.5f - clipPoint.y / clipPoint.w * 0.5f,
        );
    }

    normalize(projected[]);

    // A doorway grazing the region edge still lets a sliver through, and the
    // clip would drop the room behind it
    float cx = 0;
    float cy = 0;

    foreach(corner; projected)
    {
        cx += corner.x;
        cy += corner.y;
    }

    cx /= 4;
    cy /= 4;

    foreach(ref corner; projected)
    {
        corner.x += (corner.x - cx) * PortalGrid.grazing;
        corner.y += (corner.y - cy) * PortalGrid.grazing;
    }

    return true;
}

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

unittest
{
    // A 4 by 4 grid: the room the eye stands in is always visible, and a point
    // outside the grid clamps to its nearest room
    import dlib.math: Matrix4x4f;

    PortalGrid grid;
    grid.rooms = 4;
    grid.roomSize = 16;
    grid.wallHeight = 4;
    grid.doorwayWidth = 3;
    grid.doorwayHeight = 2.6;

    auto viewProj = Matrix4x4f.identity;
    viewProj.a43 = 1;

    const eye = Vector3f(8, 1.7f, 8);
    const seen = grid.visibleRooms(eye, viewProj);

    assert((0L in seen), "the room the eye stands in is always visible");

    int x, z;
    grid.roomOf(Vector3f(-100, 0, -100), x, z);
    assert(x == 0 && z == 0);

    // The same grid as a set of doorways sees the same rooms
    PortalSet set;
    set.portals = grid.portals();

    const throughSet = set.visibleRooms(
        PortalSet.startRooms(eye, grid.roomSize, grid.rooms), viewProj);

    assert(throughSet == seen, "the set and the grid walk the same doorways");
}
