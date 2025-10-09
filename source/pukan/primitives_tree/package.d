module pukan.primitives_tree;

import pukan.primitives_tree.mesh: Mesh;
import pukan.scene: Vertex;
import std.variant: Algebraic;
import dlib.math: Matrix4x4f;

struct Node
{
    Algebraic!(
        Bone,
        Mesh,
        PrimitivesTree,
    ) payload;

    Node[] children;
}

class PrimitivesTree
{
    Node root;
}

/// Represents the translation of an node relative to the ancestor bone node
alias Bone = Matrix4x4f;
