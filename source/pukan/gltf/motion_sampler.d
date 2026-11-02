module pukan.gltf.motion_sampler;

import dlib.math: Matrix4x4f, Vector3f, translation;
import pukan.gltf: Trans;
import pukan.gltf.animation: AnimationSupport;
import pukan.gltf.loader: GltfAsset;
import pukan.motion_matching.database: Clip, ClipPose;
import pukan.motion_matching.schema: Schema;
import pukan.motion_matching.transform: Transform, wrapAngle;
import std.exception: enforce;
import std.math: atan2, floor;

/// Reads the clips of a loaded model into the space motion matching compares.
///
/// A pose comes back as the root bone's transform plus the positions of the schema bones
/// measured from that root, which is exactly what `Database` stores. The root is the bone
/// named by the schema, or the first joint of the first skin, so it is the one that moves.
final class MotionSampler
{
    private GltfAsset asset;
    private AnimationSupport support;
    private Trans[] basePose;
    private int rootNode;
    private int[] boneNodes;
    private Matrix4x4f[] worldMatrices;
    /// Displacement and turn of one whole cycle of a clip, measured on first use
    private Vector3f[] cycleShift;
    private float[] cycleYaw;
    private bool[] cycleKnown;

    this(GltfAsset asset, Schema schema)
    {
        enforce(schema.bones.length > 0, "the schema names no bones");

        this.asset = asset;
        this.support = AnimationSupport(&asset.content, asset.nodes.length);

        basePose.length = asset.nodes.length;

        foreach(i, ref node; asset.nodes)
            basePose[i] = node.trans;

        worldMatrices.length = asset.nodes.length;

        rootNode = schema.rootBone.length ? findNode(schema.rootBone) : defaultRootNode();

        boneNodes.length = schema.bones.length;

        foreach(i, ref bone; schema.bones)
            boneNodes[i] = findNode(bone.bone);

        cycleShift.length = asset.content.animations.length;
        cycleYaw.length = asset.content.animations.length;
        cycleKnown.length = asset.content.animations.length;
    }

    /// Bounds of the schema bones at a moment of a clip, in the model's own space.
    void boneBounds(size_t clip, float time, out Vector3f min, out Vector3f max)
    {
        const float length = duration(clip);

        float local = time;

        if(length > 0)
        {
            local %= length;

            if(local < 0)
                local += length;
        }

        evaluate(clip, local);

        foreach(i, node; boneNodes)
        {
            const position = translation(worldMatrices[node]);

            if(i == 0)
            {
                min = position;
                max = position;
                continue;
            }

            min = Vector3f(
                position.x < min.x ? position.x : min.x,
                position.y < min.y ? position.y : min.y,
                position.z < min.z ? position.z : min.z,
            );

            max = Vector3f(
                position.x > max.x ? position.x : max.x,
                position.y > max.y ? position.y : max.y,
                position.z > max.z ? position.z : max.z,
            );
        }
    }

    /// Node the sampler measures every pose from.
    int rootNodeIndex() const
    {
        return rootNode;
    }

    /// Clips of the model, ready for `Database.build`.
    Clip[] clips()
    {
        Clip[] result;

        foreach(i, ref animation; asset.content.animations)
            result ~= Clip(animation.name, duration(i));

        return result;
    }

    /// Delegate for `Database.build`; valid while this sampler lives.
    ClipPose delegate(size_t clip, float time) sampler()
    {
        return &sample;
    }

    /// Length of a clip, the latest key of any of its samplers.
    float duration(size_t clip)
    {
        enforce(clip < asset.content.animations.length, "the model has no such clip");

        float result = 0;

        foreach(ref sampler; asset.content.animations[clip].samplers)
        {
            auto timeline = asset.content.rangify!float(sampler.inputAcc);

            if(timeline.length > 0 && timeline[$ - 1] > result)
                result = timeline[$ - 1];
        }

        return result;
    }

    /// Pose of `clip` at `time`.
    ///
    /// The pose repeats every cycle, but the root does not return to where it started: whole
    /// cycles add up, so the root keeps moving past the clip ends. A clip of a character
    /// walking forward therefore describes a walk that never turns back at its loop point.
    ClipPose sample(size_t clip, float time)
    {
        const length = duration(clip);

        float local = time;
        float cycles = 0;

        if(length > 0)
        {
            cycles = floor(time / length);
            local = time - cycles * length;
        }
        else
            local = 0;

        auto result = evaluate(clip, local);

        if(cycles != 0)
        {
            measureCycle(clip);

            result.root.translation += cycleShift[clip] * cycles;
            result.root.yaw += cycleYaw[clip] * cycles;
        }

        return result;
    }

    private ClipPose evaluate(size_t clip, float local)
    {
        support.currTime = local;
        support.setPose(&asset.content.animations[clip], basePose);

        worldMatrices[] = Matrix4x4f.identity;

        foreach(child; asset.rootSceneNode.childrenNodeIndices)
            accumulate(child, Matrix4x4f.identity);

        const root = worldMatrices[rootNode];
        const rootInverse = root.inverse;

        ClipPose result;
        result.root = Transform(
            translation(root),
            atan2(root.a13, root.a33),
        );

        foreach(node; boneNodes)
            result.bones ~= translation(rootInverse * worldMatrices[node]);

        return result;
    }

    /// Measures what one whole cycle of `clip` adds to the root.
    private void measureCycle(size_t clip)
    {
        if(cycleKnown[clip])
            return;

        cycleKnown[clip] = true;

        const length = duration(clip);

        if(length <= 0)
            return;

        const start = evaluate(clip, 0);

        // The last key sits at the clip length, which the sampler would wrap back to zero
        const finish = evaluate(clip, length - 1e-4f);

        cycleShift[clip] = finish.root.translation - start.root.translation;
        cycleYaw[clip] = wrapAngle(finish.root.yaw - start.root.yaw);
    }

    private void accumulate(size_t node, Matrix4x4f parent)
    {
        const matrix = parent * support.perNodeTranslations[node].calcMatrix;
        worldMatrices[node] = matrix;

        foreach(child; asset.nodes[node].childrenNodeIndices)
            accumulate(child, matrix);
    }

    private int defaultRootNode() const
    {
        if(asset.content.skins.length > 0 && asset.content.skins[0].nodesIndices.length > 0)
            return cast(int) asset.content.skins[0].nodesIndices[0];

        enforce(asset.rootSceneNode.childrenNodeIndices.length > 0, "the model has no nodes");

        return cast(int) asset.rootSceneNode.childrenNodeIndices[0];
    }

    private int findNode(string name) const
    {
        foreach(i, ref node; asset.nodes)
            if(node.payload.name == name)
                return cast(int) i;

        // Exporters disagree about the case of bone names, so the second pass ignores it
        import std.uni: toLower;

        const wanted = name.toLower;

        foreach(i, ref node; asset.nodes)
            if(node.payload.name.toLower == wanted)
                return cast(int) i;

        throw new Exception("the model has no node named " ~ name);
    }
}
