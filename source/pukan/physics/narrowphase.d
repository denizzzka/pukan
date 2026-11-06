module pukan.physics.narrowphase;

import dlib.math: Matrix4x4f, Vector3f, cross, dot;
import pukan.physics.shapes: Aabb, transformDirection, transformPoint;
import std.algorithm: clamp, max, min;
import std.math: abs, sqrt;

private enum contactEpsilon = 1e-5f;

/// Ray against an axis-aligned box; `t` is the entry distance
bool rayAabb(in Aabb box, in Vector3f origin, in Vector3f direction, float maxT, out float t)
{
    float tmin = 0.0f;
    float tmax = maxT;

    foreach(axis; 0 .. 3)
    {
        if(abs(direction[axis]) < 1e-8f)
        {
            if(origin[axis] < box.min[axis] || origin[axis] > box.max[axis])
                return false;

            continue;
        }

        const inverse = 1.0f / direction[axis];
        float t1 = (box.min[axis] - origin[axis]) * inverse;
        float t2 = (box.max[axis] - origin[axis]) * inverse;

        if(t1 > t2)
        {
            const swap = t1;
            t1 = t2;
            t2 = swap;
        }

        tmin = max(tmin, t1);
        tmax = min(tmax, t2);

        if(tmin > tmax)
            return false;
    }

    t = tmin;

    return true;
}

/// Ray against a triangle; `normal` faces the ray origin
bool rayTriangle(
    in Vector3f origin,
    in Vector3f direction,
    in Vector3f a,
    in Vector3f b,
    in Vector3f c,
    float maxT,
    out float t,
    out Vector3f normal,
)
{
    const edge1 = b - a;
    const edge2 = c - a;
    const pvec = cross(direction, edge2);
    const det = dot(edge1, pvec);

    if(abs(det) < 1e-8f)
        return false;

    const inverse = 1.0f / det;
    const tvec = origin - a;
    const u = dot(tvec, pvec) * inverse;

    if(u < 0.0f || u > 1.0f)
        return false;

    const qvec = cross(tvec, edge1);
    const v = dot(direction, qvec) * inverse;

    if(v < 0.0f || u + v > 1.0f)
        return false;

    t = dot(edge2, qvec) * inverse;

    if(t < 0.0f || t > maxT)
        return false;

    normal = cross(edge1, edge2).normalized;

    if(dot(normal, direction) > 0.0f)
        normal = -normal;

    return true;
}

/// Ray against a sphere
bool raySphere(
    in Vector3f center,
    float radius,
    in Vector3f origin,
    in Vector3f direction,
    float maxT,
    out float t,
)
{
    const oc = origin - center;
    const a = dot(direction, direction);
    const b = 2.0f * dot(oc, direction);
    const c = dot(oc, oc) - radius * radius;
    const discriminant = b * b - 4.0f * a * c;

    if(discriminant < 0.0f)
        return false;

    const root = sqrt(discriminant);
    float near = (-b - root) / (2.0f * a);
    const far = (-b + root) / (2.0f * a);

    if(near < 0.0f)
        near = far;

    if(near < 0.0f || near > maxT)
        return false;

    t = near;

    return true;
}

/// Closest point on a segment to a point
Vector3f closestPointOnSegment(in Vector3f a, in Vector3f b, in Vector3f point)
{
    const ab = b - a;
    const lengthSquared = dot(ab, ab);

    if(lengthSquared < 1e-12f)
        return a;

    return a + ab * clamp(dot(point - a, ab) / lengthSquared, 0.0f, 1.0f);
}

/// Closest point on a triangle to a point, with its barycentric weights
private Vector3f closestPointOnTriangleWeights(
    in Vector3f point,
    in Vector3f a,
    in Vector3f b,
    in Vector3f c,
    out float weightA,
    out float weightB,
    out float weightC,
)
{
    const ab = b - a;
    const ac = c - a;
    const ap = point - a;
    const d1 = dot(ab, ap);
    const d2 = dot(ac, ap);

    if(d1 <= 0.0f && d2 <= 0.0f)
    {
        weightA = 1.0f;
        weightB = 0.0f;
        weightC = 0.0f;
        return a;
    }

    const bp = point - b;
    const d3 = dot(ab, bp);
    const d4 = dot(ac, bp);

    if(d3 >= 0.0f && d4 <= d3)
    {
        weightA = 0.0f;
        weightB = 1.0f;
        weightC = 0.0f;
        return b;
    }

    const vc = d1 * d4 - d3 * d2;

    if(vc <= 0.0f && d1 >= 0.0f && d3 <= 0.0f)
    {
        const v = d1 / (d1 - d3);
        weightA = 1.0f - v;
        weightB = v;
        weightC = 0.0f;
        return a + ab * v;
    }

    const cp = point - c;
    const d5 = dot(ab, cp);
    const d6 = dot(ac, cp);

    if(d6 >= 0.0f && d5 <= d6)
    {
        weightA = 0.0f;
        weightB = 0.0f;
        weightC = 1.0f;
        return c;
    }

    const vb = d5 * d2 - d1 * d6;

    if(vb <= 0.0f && d2 >= 0.0f && d6 <= 0.0f)
    {
        const w = d2 / (d2 - d6);
        weightA = 1.0f - w;
        weightB = 0.0f;
        weightC = w;
        return a + ac * w;
    }

    const va = d3 * d6 - d5 * d4;

    if(va <= 0.0f && d4 - d3 >= 0.0f && d5 - d6 >= 0.0f)
    {
        const w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        weightA = 0.0f;
        weightB = 1.0f - w;
        weightC = w;
        return b + (c - b) * w;
    }

    const denominator = 1.0f / (va + vb + vc);
    const v = vb * denominator;
    const w = vc * denominator;
    weightA = 1.0f - v - w;
    weightB = v;
    weightC = w;

    return a + ab * v + ac * w;
}

/// Closest point on a triangle to a point
Vector3f closestPointOnTriangle(
    in Vector3f point,
    in Vector3f a,
    in Vector3f b,
    in Vector3f c,
)
{
    float weightA;
    float weightB;
    float weightC;

    return closestPointOnTriangleWeights(point, a, b, c, weightA, weightB, weightC);
}

/// Squared distance from a point to a centered box `[-halfExtents, halfExtents]`
float pointAabbDistanceSquared(in Vector3f point, in Vector3f halfExtents)
{
    Vector3f delta;

    foreach(axis; 0 .. 3)
    {
        if(point[axis] < -halfExtents[axis])
            delta[axis] = -halfExtents[axis] - point[axis];
        else if(point[axis] > halfExtents[axis])
            delta[axis] = point[axis] - halfExtents[axis];
        else
            delta[axis] = 0.0f;
    }

    return dot(delta, delta);
}

/// Closest point on a centered box to a point
Vector3f closestPointOnAabb(in Vector3f point, in Vector3f halfExtents)
{
    return Vector3f(
        clamp(point.x, -halfExtents.x, halfExtents.x),
        clamp(point.y, -halfExtents.y, halfExtents.y),
        clamp(point.z, -halfExtents.z, halfExtents.z),
    );
}

/// Closest points between two segments
float segmentSegmentDistanceSquared(
    in Vector3f a0,
    in Vector3f a1,
    in Vector3f b0,
    in Vector3f b1,
    out Vector3f closestA,
    out Vector3f closestB,
)
{
    const d1 = a1 - a0;
    const d2 = b1 - b0;
    const r = a0 - b0;
    const a = dot(d1, d1);
    const e = dot(d2, d2);
    const f = dot(d2, r);

    float s;
    float t;

    if(a <= 1e-12f && e <= 1e-12f)
    {
        s = 0.0f;
        t = 0.0f;
    }
    else if(a <= 1e-12f)
    {
        s = 0.0f;
        t = clamp(f / e, 0.0f, 1.0f);
    }
    else
    {
        const c = dot(d1, r);

        if(e <= 1e-12f)
        {
            t = 0.0f;
            s = clamp(-c / a, 0.0f, 1.0f);
        }
        else
        {
            const b = dot(d1, d2);
            const denominator = a * e - b * b;

            s = denominator != 0.0f
                ? clamp((b * f - c * e) / denominator, 0.0f, 1.0f)
                : 0.0f;

            t = (b * s + f) / e;

            if(t < 0.0f)
            {
                t = 0.0f;
                s = clamp(-c / a, 0.0f, 1.0f);
            }
            else if(t > 1.0f)
            {
                t = 1.0f;
                s = clamp((b - c) / a, 0.0f, 1.0f);
            }
        }
    }

    closestA = a0 + d1 * s;
    closestB = b0 + d2 * t;

    return dot(closestA - closestB, closestA - closestB);
}

/// Closest points between a segment and a centered box
float segmentAabbDistanceSquared(
    in Vector3f a,
    in Vector3f b,
    in Vector3f halfExtents,
    out Vector3f closestA,
    out Vector3f closestB,
)
{
    const box = Aabb(-halfExtents, halfExtents);
    float hitT;

    if(rayAabb(box, a, b - a, 1.0f, hitT))
    {
        closestA = a + (b - a) * hitT;
        closestB = closestA;
        return 0.0f;
    }

    float best = pointAabbDistanceSquared(a, halfExtents);
    closestA = a;
    closestB = closestPointOnAabb(a, halfExtents);

    const distanceB = pointAabbDistanceSquared(b, halfExtents);

    if(distanceB < best)
    {
        best = distanceB;
        closestA = b;
        closestB = closestPointOnAabb(b, halfExtents);
    }

    static immutable uint[2][12] edges = [
        [0, 1], [0, 2], [0, 4], [1, 3], [1, 5], [2, 3],
        [2, 6], [3, 7], [4, 5], [4, 6], [5, 7], [6, 7],
    ];

    Vector3f[8] corners;

    foreach(i; 0 .. 8)
        corners[i] = Vector3f(
            (i & 1) ? halfExtents.x : -halfExtents.x,
            (i & 2) ? halfExtents.y : -halfExtents.y,
            (i & 4) ? halfExtents.z : -halfExtents.z,
        );

    foreach(edge; edges)
    {
        Vector3f segmentA;
        Vector3f segmentB;
        const distance = segmentSegmentDistanceSquared(
            a, b, corners[edge[0]], corners[edge[1]], segmentA, segmentB);

        if(distance < best)
        {
            best = distance;
            closestA = segmentA;
            closestB = segmentB;
        }
    }

    return best;
}

/// Closest points between a segment and a triangle
float segmentTriangleDistanceSquared(
    in Vector3f a,
    in Vector3f b,
    in Vector3f p0,
    in Vector3f p1,
    in Vector3f p2,
    out Vector3f closestA,
    out Vector3f closestB,
)
{
    float hitT;
    Vector3f normal;

    if(rayTriangle(a, b - a, p0, p1, p2, 1.0f, hitT, normal))
    {
        closestA = a + (b - a) * hitT;
        closestB = closestA;
        return 0.0f;
    }

    float best = (a - closestPointOnTriangle(a, p0, p1, p2)).lengthsqr;
    closestA = a;
    closestB = closestPointOnTriangle(a, p0, p1, p2);

    const distanceB = (b - closestPointOnTriangle(b, p0, p1, p2)).lengthsqr;

    if(distanceB < best)
    {
        best = distanceB;
        closestA = b;
        closestB = closestPointOnTriangle(b, p0, p1, p2);
    }

    Vector3f[3] edgesStart = [p0, p1, p2];
    Vector3f[3] edgesEnd = [p1, p2, p0];

    foreach(i; 0 .. 3)
    {
        Vector3f segmentA;
        Vector3f segmentB;
        const distance = segmentSegmentDistanceSquared(
            a, b, edgesStart[i], edgesEnd[i], segmentA, segmentB);

        if(distance < best)
        {
            best = distance;
            closestA = segmentA;
            closestB = segmentB;
        }
    }

    return best;
}

/// A vertex of the Minkowski difference `segment - hull` used by GJK
private struct GjkVertex
{
    Vector3f w;
    Vector3f a;
    Vector3f b;
}

private struct GjkProjection
{
    float distanceSquared = float.infinity;
    Vector3f w;
    size_t count;
    GjkVertex[4] vertices;
    float[4] weights;
}

/// Support point of `segment - hull` in `direction`
private GjkVertex supportSegmentHull(
    in Vector3f a,
    in Vector3f b,
    in Vector3f[] points,
    in Vector3f direction,
)
{
    const segmentPoint = dot(a, direction) >= dot(b, direction) ? a : b;

    size_t index;
    auto best = -dot(points[0], direction);

    foreach(i; 1 .. points.length)
    {
        const projection = -dot(points[i], direction);

        if(projection > best)
        {
            best = projection;
            index = i;
        }
    }

    const hullPoint = Vector3f(points[index].x, points[index].y, points[index].z);

    return GjkVertex(segmentPoint - hullPoint, segmentPoint, hullPoint);
}

private bool originInsideTetra(in Vector3f[4] points)
{
    const volume = dot(cross(points[1] - points[0], points[2] - points[0]),
        points[3] - points[0]);

    // A coplanar tetra has no interior; its faces already give the distance
    if(abs(volume) < 1e-9f)
        return false;

    bool sameSide(in Vector3f vertex, in Vector3f a, in Vector3f b, in Vector3f c)
    {
        const originSide = dot(cross(b - a, c - a), -a);
        const vertexSide = dot(cross(b - a, c - a), vertex - a);

        return originSide * vertexSide >= 0.0f;
    }

    return sameSide(points[3], points[0], points[1], points[2])
        && sameSide(points[2], points[0], points[1], points[3])
        && sameSide(points[1], points[0], points[2], points[3])
        && sameSide(points[0], points[1], points[2], points[3]);
}

/// Closest point to the origin of the simplex, reduced to the feature holding it
private GjkProjection projectSimplex(in GjkVertex[4] vertices, size_t count)
{
    GjkProjection best;

    void keep(scope const(size_t)[] indices, scope const(float)[] weights, Vector3f w)
    {
        const distanceSquared = dot(w, w);

        if(distanceSquared >= best.distanceSquared)
            return;

        best.distanceSquared = distanceSquared;
        best.w = w;
        best.count = indices.length;

        foreach(i; 0 .. indices.length)
        {
            best.vertices[i] = vertices[indices[i]];
            best.weights[i] = weights[i];
        }
    }

    foreach(i; 0 .. count)
    {
        size_t[4] indices = [i, 0, 0, 0];
        float[4] weights = [1.0f, 0.0f, 0.0f, 0.0f];

        keep(indices[0 .. 1], weights[0 .. 1], vertices[i].w);
    }

    static immutable uint[2][6] pairs = [
        [0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3],
    ];

    foreach(pair; pairs)
    {
        if(pair[0] >= count || pair[1] >= count)
            continue;

        const start = vertices[pair[0]].w;
        const edge = vertices[pair[1]].w - start;
        const lengthSquared = dot(edge, edge);
        const t = lengthSquared > 1e-12f
            ? clamp(-dot(start, edge) / lengthSquared, 0.0f, 1.0f)
            : 0.0f;

        size_t[4] indices;
        float[4] weights;
        size_t kept;

        if(1.0f - t > 1e-6f)
        {
            indices[kept] = pair[0];
            weights[kept] = 1.0f - t;
            ++kept;
        }

        if(t > 1e-6f)
        {
            indices[kept] = pair[1];
            weights[kept] = t;
            ++kept;
        }

        if(kept == 0)
        {
            indices[0] = pair[0];
            weights[0] = 1.0f;
            kept = 1;
        }

        keep(indices[0 .. kept], weights[0 .. kept], start + edge * t);
    }

    static immutable uint[3][4] triples = [
        [0, 1, 2], [0, 1, 3], [0, 2, 3], [1, 2, 3],
    ];

    Vector3f[4] tetraPoints;

    foreach(i; 0 .. 4)
        tetraPoints[i] = vertices[i].w;

    if(count == 4 && originInsideTetra(tetraPoints))
    {
        best.distanceSquared = 0.0f;
        best.w = Vector3f(0, 0, 0);
        best.count = 0;

        return best;
    }

    foreach(triple; triples)
    {
        if(triple[0] >= count || triple[1] >= count || triple[2] >= count)
            continue;

        const area = cross(
            vertices[triple[1]].w - vertices[triple[0]].w,
            vertices[triple[2]].w - vertices[triple[0]].w,
        );

        if(area.lengthsqr < 1e-12f)
            continue;

        float weightA;
        float weightB;
        float weightC;
        const point = closestPointOnTriangleWeights(
            Vector3f(0, 0, 0),
            vertices[triple[0]].w,
            vertices[triple[1]].w,
            vertices[triple[2]].w,
            weightA,
            weightB,
            weightC,
        );

        const float[3] allWeights = [weightA, weightB, weightC];
        size_t[4] indices;
        float[4] weights;
        size_t kept;

        foreach(i; 0 .. 3)
        {
            if(allWeights[i] > 1e-6f)
            {
                indices[kept] = triple[i];
                weights[kept] = allWeights[i];
                ++kept;
            }
        }

        if(kept == 0)
        {
            indices[0] = triple[0];
            weights[0] = 1.0f;
            kept = 1;
        }

        keep(indices[0 .. kept], weights[0 .. kept], point);
    }

    return best;
}

/**
    Closest points between a segment and the convex hull of `points`, by GJK.
    The points are the hull vertices in any order; their convex hull is the shape.
*/
float segmentConvexDistanceSquared(
    in Vector3f a,
    in Vector3f b,
    in Vector3f[] points,
    out Vector3f closestA,
    out Vector3f closestB,
)
{
    closestA = a;
    closestB = a;

    if(points.length == 0)
        return 0.0f;

    auto centroid = Vector3f(0, 0, 0);
    foreach(point; points)
        centroid += point;
    centroid /= cast(float) points.length;

    auto direction = (a + b) * 0.5f - centroid;

    if(direction.lengthsqr < 1e-12f)
        direction = Vector3f(1, 0, 0);

    GjkVertex[4] simplex;
    simplex[0] = supportSegmentHull(a, b, points, direction);

    auto projection = projectSimplex(simplex, 1);

    foreach(iteration; 0 .. 32)
    {
        const v = projection.w;
        const distanceSquared = projection.distanceSquared;

        if(distanceSquared <= 1e-12f)
        {
            closestA = (a + b) * 0.5f;
            closestB = closestA;
            return 0.0f;
        }

        const support = supportSegmentHull(a, b, points, -v);

        // The current closest point already supports its own direction
        if(dot(support.w, v) >= distanceSquared - 1e-7f * max(1.0f, distanceSquared))
            break;

        bool duplicate;

        foreach(i; 0 .. projection.count)
            if((support.w - projection.vertices[i].w).lengthsqr < 1e-12f)
            {
                duplicate = true;
                break;
            }

        if(duplicate)
            break;

        // The projection kept a compacted simplex, so rebuild it before growing
        foreach(i; 0 .. projection.count)
            simplex[i] = projection.vertices[i];

        simplex[projection.count] = support;
        projection = projectSimplex(simplex, projection.count + 1);
    }

    closestA = Vector3f(0, 0, 0);
    closestB = Vector3f(0, 0, 0);

    foreach(i; 0 .. projection.count)
    {
        closestA += projection.vertices[i].a * projection.weights[i];
        closestB += projection.vertices[i].b * projection.weights[i];
    }

    return projection.distanceSquared;
}

private Vector3f triangleNormal(in Vector3f a, in Vector3f b, in Vector3f c, in Vector3f motion)
{
    auto normal = cross(b - a, c - a).normalized;

    if(dot(normal, motion) > 0.0f)
        normal = -normal;

    return normal;
}

/// Moving capsule against a triangle, conservative advancement
bool sweepCapsuleTriangle(
    in Vector3f a,
    in Vector3f b,
    float radius,
    in Vector3f motion,
    in Vector3f p0,
    in Vector3f p1,
    in Vector3f p2,
    float margin,
    out float fraction,
    out Vector3f point,
    out Vector3f normal,
)
{
    const motionLength = motion.length;

    if(motionLength < 1e-8f)
    {
        Vector3f closestA;
        Vector3f closestB;
        const distance = sqrt(segmentTriangleDistanceSquared(a, b, p0, p1, p2, closestA, closestB));

        if(distance > radius + margin + contactEpsilon)
            return false;

        fraction = 0.0f;
        point = closestB;
        normal = distance > 1e-6f
            ? (closestA - closestB).normalized
            : triangleNormal(p0, p1, p2, Vector3f(0, 0, 0));

        return true;
    }

    float t = 0.0f;

    foreach(iteration; 0 .. 16)
    {
        Vector3f closestA;
        Vector3f closestB;
        const distance = sqrt(segmentTriangleDistanceSquared(
            a + motion * t, b + motion * t, p0, p1, p2, closestA, closestB));
        const gap = distance - radius - margin;

        if(gap <= contactEpsilon)
        {
            fraction = t;
            point = closestB;
            normal = distance > 1e-6f
                ? (closestA - closestB).normalized
                : triangleNormal(p0, p1, p2, motion);

            return true;
        }

        const advance = gap / motionLength;

        if(advance <= 1e-6f)
            break;

        t += advance;

        if(t > 1.0f)
            break;
    }

    return false;
}

/// Moving capsule against a sphere, conservative advancement
bool sweepCapsuleSphere(
    in Vector3f a,
    in Vector3f b,
    float capsuleRadius,
    in Vector3f center,
    float radius,
    in Vector3f motion,
    float margin,
    out float fraction,
    out Vector3f point,
    out Vector3f normal,
)
{
    const motionLength = motion.length;

    if(motionLength < 1e-8f)
    {
        const closest = closestPointOnSegment(a, b, center);
        const delta = closest - center;

        if(delta.length > capsuleRadius + radius + margin + contactEpsilon)
            return false;

        fraction = 0.0f;
        normal = delta.length > 1e-6f ? delta.normalized : Vector3f(0, 1, 0);
        point = center + normal * radius;

        return true;
    }

    float t = 0.0f;

    foreach(iteration; 0 .. 16)
    {
        const closest = closestPointOnSegment(a + motion * t, b + motion * t, center);
        const delta = closest - center;
        const gap = delta.length - capsuleRadius - radius - margin;

        if(gap <= contactEpsilon)
        {
            fraction = t;
            normal = delta.length > 1e-6f ? delta.normalized : -motion.normalized;
            point = center + normal * radius;

            return true;
        }

        const advance = gap / motionLength;

        if(advance <= 1e-6f)
            break;

        t += advance;

        if(t > 1.0f)
            break;
    }

    return false;
}

private Vector3f insideBoxNormal(in Vector3f point, in Vector3f halfExtents)
{
    const distances = Vector3f(
        halfExtents.x - abs(point.x),
        halfExtents.y - abs(point.y),
        halfExtents.z - abs(point.z),
    );

    if(distances.x <= distances.y && distances.x <= distances.z)
        return Vector3f(point.x >= 0.0f ? 1.0f : -1.0f, 0, 0);

    if(distances.y <= distances.z)
        return Vector3f(0, point.y >= 0.0f ? 1.0f : -1.0f, 0);

    return Vector3f(0, 0, point.z >= 0.0f ? 1.0f : -1.0f);
}

/// Moving capsule against a transformed box, conservative advancement
bool sweepCapsuleBox(
    in Vector3f a,
    in Vector3f b,
    float radius,
    in Vector3f motion,
    in Matrix4x4f transform,
    in Vector3f halfExtents,
    float margin,
    out float fraction,
    out Vector3f point,
    out Vector3f normal,
)
{
    const inverse = transform.inverse;
    const localA = transformPoint(a, inverse);
    const localB = transformPoint(b, inverse);
    const localMotion = transformDirection(motion, inverse);
    const motionLength = localMotion.length;

    if(motionLength < 1e-8f)
    {
        Vector3f closestA;
        Vector3f closestB;
        const distance = sqrt(segmentAabbDistanceSquared(
            localA, localB, halfExtents, closestA, closestB));

        if(distance > radius + margin + contactEpsilon)
            return false;

        fraction = 0.0f;
        const localNormal = distance > 1e-6f
            ? (closestA - closestB).normalized
            : insideBoxNormal((localA + localB) * 0.5f, halfExtents);
        normal = transformDirection(localNormal, transform).normalized;
        point = transformPoint(closestB, transform);

        return true;
    }

    float t = 0.0f;

    foreach(iteration; 0 .. 16)
    {
        Vector3f closestA;
        Vector3f closestB;
        const distance = sqrt(segmentAabbDistanceSquared(
            localA + localMotion * t, localB + localMotion * t, halfExtents, closestA, closestB));
        const gap = distance - radius - margin;

        if(gap <= contactEpsilon)
        {
            fraction = t;
            const localNormal = distance > 1e-6f
                ? (closestA - closestB).normalized
                : insideBoxNormal((closestA + closestB) * 0.5f, halfExtents);
            normal = transformDirection(localNormal, transform).normalized;
            point = transformPoint(closestB, transform);

            return true;
        }

        const advance = gap / motionLength;

        if(advance <= 1e-6f)
            break;

        t += advance;

        if(t > 1.0f)
            break;
    }

    return false;
}

/// Moving capsule against a convex hull of `points`, conservative advancement
bool sweepCapsuleConvex(
    in Vector3f a,
    in Vector3f b,
    float radius,
    in Vector3f motion,
    in Matrix4x4f transform,
    in Vector3f[] points,
    float margin,
    out float fraction,
    out Vector3f point,
    out Vector3f normal,
)
{
    const inverse = transform.inverse;
    const localA = transformPoint(a, inverse);
    const localB = transformPoint(b, inverse);
    const localMotion = transformDirection(motion, inverse);
    const motionLength = localMotion.length;

    auto centroid = Vector3f(0, 0, 0);
    foreach(vertex; points)
        centroid += vertex;
    centroid /= cast(float) points.length;

    if(motionLength < 1e-8f)
    {
        Vector3f closestA;
        Vector3f closestB;
        const distance = sqrt(segmentConvexDistanceSquared(
            localA, localB, points, closestA, closestB));

        if(distance > radius + margin + contactEpsilon)
            return false;

        fraction = 0.0f;
        const localNormal = distance > 1e-6f
            ? (closestA - closestB).normalized
            : ((localA + localB) * 0.5f - centroid).normalized;
        normal = transformDirection(localNormal, transform).normalized;
        point = transformPoint(closestB, transform);

        return true;
    }

    float t = 0.0f;
    Vector3f lastNormal;
    Vector3f lastHullPoint;
    bool hasContact;

    foreach(iteration; 0 .. 16)
    {
        Vector3f closestA;
        Vector3f closestB;
        const distance = sqrt(segmentConvexDistanceSquared(
            localA + localMotion * t, localB + localMotion * t,
            points, closestA, closestB));
        const gap = distance - radius - margin;

        if(gap <= contactEpsilon)
        {
            fraction = t;
            // The last separated step holds the surface normal when the
            // contact lands exactly on the hull and GJK sees no separation
            const localNormal = distance > 1e-6f
                ? (closestA - closestB).normalized
                : hasContact ? lastNormal : ((closestA + closestB) * 0.5f - centroid).normalized;
            normal = transformDirection(localNormal, transform).normalized;
            point = transformPoint(distance > 1e-6f || !hasContact ? closestB : lastHullPoint,
                transform);

            return true;
        }

        if(distance > 1e-6f)
        {
            lastNormal = (closestA - closestB).normalized;
            lastHullPoint = closestB;
            hasContact = true;
        }

        const advance = gap / motionLength;

        if(advance <= 1e-6f)
            break;

        t += advance;

        if(t > 1.0f)
            break;
    }

    return false;
}

unittest
{
    const floor = Aabb(Vector3f(-10, -1, -10), Vector3f(10, 0, 10));

    float t;
    assert(rayAabb(floor, Vector3f(0, 5, 0), Vector3f(0, -1, 0), 100, t));
    assert(abs(t - 5) < 1e-5f);

    Vector3f normal;
    assert(rayTriangle(
        Vector3f(0, 1, 0), Vector3f(0, -1, 0),
        Vector3f(-1, 0, -1), Vector3f(1, 0, -1), Vector3f(0, 0, 1),
        10, t, normal));
    assert(abs(t - 1) < 1e-5f);
    assert(normal.y > 0.9f);

    assert(raySphere(Vector3f(0, 0, 0), 1, Vector3f(0, 0, 5), Vector3f(0, 0, -1), 10, t));
    assert(abs(t - 4) < 1e-5f);

    const point = closestPointOnTriangle(
        Vector3f(0, 1, 0), Vector3f(-1, 0, -1), Vector3f(1, 0, -1), Vector3f(0, 0, 1));
    assert(abs(point.y) < 1e-5f);

    Vector3f closestA;
    Vector3f closestB;
    const distance = sqrt(segmentTriangleDistanceSquared(
        Vector3f(0, 1, 0), Vector3f(0, 2, 0),
        Vector3f(-1, 0, -1), Vector3f(1, 0, -1), Vector3f(0, 0, 1),
        closestA, closestB));
    assert(abs(distance - 1) < 1e-5f);

    assert(sweepCapsuleTriangle(
        Vector3f(0, 1, 0), Vector3f(0, 2, 0), 0.5f, Vector3f(0, -2, 0),
        Vector3f(-1, 0, -1), Vector3f(1, 0, -1), Vector3f(0, 0, 1),
        0.001f, t, closestA, normal));
    assert(t > 0.2f && t < 0.3f);
    assert(normal.y > 0.9f);

    assert(sweepCapsuleBox(
        Vector3f(0, 1.5f, 0), Vector3f(0, 2.5f, 0), 0.5f, Vector3f(0, -2, 0),
        Matrix4x4f.identity, Vector3f(1, 0.5f, 1),
        0.001f, t, closestA, normal));
    assert(t > 0.2f && t < 0.3f);
    assert(normal.y > 0.9f);
}

unittest
{
    import std.math: sqrt;

    // A cube as a convex hull, with its points in no useful order
    const Vector3f[] cube = [
        Vector3f(-1, -1, -1), Vector3f(1, -1, -1), Vector3f(1, 1, -1), Vector3f(-1, 1, -1),
        Vector3f(-1, -1, 1), Vector3f(1, -1, 1), Vector3f(1, 1, 1), Vector3f(-1, 1, 1),
    ];

    Vector3f closestA;
    Vector3f closestB;

    // A segment above the top face
    const above = segmentConvexDistanceSquared(
        Vector3f(0, 3, 0), Vector3f(1, 3, 0), cube, closestA, closestB);
    assert(abs(sqrt(above) - 2.0f) < 1e-3f);
    assert(abs(closestB.y - 1.0f) < 1e-3f);
    assert(abs(closestA.y - 3.0f) < 1e-3f);

    // Beside a vertical face: the closest feature is that face
    const beside = segmentConvexDistanceSquared(
        Vector3f(2, 0, 0), Vector3f(2, 0.5f, 0), cube, closestA, closestB);
    assert(abs(sqrt(beside) - 1.0f) < 1e-3f);
    assert(abs(closestB.x - 1.0f) < 1e-3f);
    assert(closestB.y >= -1e-3f && closestB.y <= 0.5f + 1e-3f);

    // Beside a corner: the closest feature is that vertex
    const corner = segmentConvexDistanceSquared(
        Vector3f(3, 3, 3), Vector3f(3, 4, 3), cube, closestA, closestB);
    assert(abs(sqrt(corner) - sqrt(12.0f)) < 2e-3f);
    assert(abs(closestB.x - 1.0f) < 2e-3f);
    assert(abs(closestB.y - 1.0f) < 2e-3f);
    assert(abs(closestB.z - 1.0f) < 2e-3f);

    // GJK agrees with the box fast path for the same cube
    const Vector3f[] samples = [
        Vector3f(0, 3, 0), Vector3f(2, 2, 0), Vector3f(3, 3, 3),
        Vector3f(-2, 0.5f, 0.5f), Vector3f(0.5f, 0.5f, 2),
        Vector3f(2, 0.25f, -1.5f), Vector3f(-3, -3, -3),
    ];

    foreach(sample; samples)
    {
        Vector3f boxA;
        Vector3f boxB;
        const boxDistance = segmentAabbDistanceSquared(
            sample, sample + Vector3f(0, 1, 0), Vector3f(1, 1, 1), boxA, boxB);
        const hullDistance = segmentConvexDistanceSquared(
            sample, sample + Vector3f(0, 1, 0), cube, closestA, closestB);

        assert(abs(boxDistance - hullDistance) < 1e-4f * max(1.0f, boxDistance));
    }

    float t;
    Vector3f point;
    Vector3f normal;

    assert(sweepCapsuleConvex(
        Vector3f(0, 3, 0), Vector3f(0, 4, 0), 0.5f, Vector3f(0, -4, 0),
        Matrix4x4f.identity, cube, 0.001f, t, point, normal));
    assert(abs(t - 0.375f) < 0.02f);
    assert(normal.y > 0.9f);

    assert(sweepCapsuleConvex(
        Vector3f(-3, 0, 0), Vector3f(-3, 1, 0), 0.5f, Vector3f(4, 0, 0),
        Matrix4x4f.identity, cube, 0.001f, t, point, normal));
    assert(abs(t - 0.375f) < 0.02f);
    assert(normal.x < -0.9f);

    // A moved hull still reports its contact in world space
    import dlib.math: translationMatrix;

    const transform = translationMatrix(Vector3f(5, 6, 0));

    assert(sweepCapsuleConvex(
        Vector3f(5, 9, 0), Vector3f(5, 10, 0), 0.5f, Vector3f(0, -4, 0),
        transform, cube, 0.001f, t, point, normal));
    assert(normal.y > 0.9f);
    assert(abs(point.y - 7.0f) < 0.05f);

    // A segment inside the hull is a contact with no separation
    assert(sweepCapsuleConvex(
        Vector3f(0, 0, 0), Vector3f(0, 0.5f, 0), 0.5f, Vector3f(0, 0, 0),
        Matrix4x4f.identity, cube, 0.001f, t, point, normal));
    assert(t == 0.0f, "inside fraction");
    assert(normal.length > 0.9f, "inside normal");
}
