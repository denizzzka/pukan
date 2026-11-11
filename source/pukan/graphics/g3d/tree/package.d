module pukan.graphics.g3d.tree;

import dlib.math: Matrix4x4f;
import std.container.slist;
import std.traits;

class Node
{
    SList!Node children;

    alias RT = ReturnType!(children.opSlice);

    RT addChildNode(Node c)
    {
        children.insert(c);

        return children.opSlice();
    }

    void traversal(void delegate(Node) dg)
    {
        dg(this);

        foreach(c; children)
            c.traversal(dg);
    }
}

/// What a walk of a node's subtree does after its visitor returns
enum Walk : ubyte
{
    descend, // visit the children
    skip,    // leave the children out and continue with the siblings
    stop,    // end the whole walk
}

/// Visits each node with the transform accumulated from its ancestors.
/// `localOf` returns the node's transform relative to its parent.
Walk walkTree(N)(
    N node,
    in Matrix4x4f parent,
    scope Matrix4x4f delegate(N) localOf,
    scope Walk delegate(N, in Matrix4x4f world, in Matrix4x4f local) visit,
)
{
    Matrix4x4f local = localOf(node);
    Matrix4x4f world = parent;
    world *= local;

    const decision = visit(node, world, local);

    if(decision == Walk.stop)
        return Walk.stop;

    if(decision == Walk.descend)
        foreach(child; node.children)
            if(walkTree!N(cast(N) child, world, localOf, visit) == Walk.stop)
                return Walk.stop;

    return Walk.descend;
}

unittest
{
    class DerrNode : Node
    {
        int payload;

        Node.RT addChildNode()
        {
            auto n = new DerrNode;
            return super.addChildNode(n);
        }
    }

    auto root = new DerrNode;
    auto n = root.addChildNode();

    root.traversal((n){ (cast(DerrNode) n).payload = 123; });
}

unittest
{
    import dlib.math: Vector3f, translationMatrix;

    static class TestNode
    {
        string name;
        float x;
        TestNode[] children;

        this(string name, float x)
        {
            this.name = name;
            this.x = x;
        }

        TestNode add(TestNode child)
        {
            children ~= child;

            return child;
        }
    }

    auto translate(TestNode n) => Vector3f(n.x, 0, 0).translationMatrix;

    auto root = new TestNode("root", 1);
    auto a = root.add(new TestNode("a", 2));
    auto b = root.add(new TestNode("b", 3));
    a.add(new TestNode("a1", 4));

    string[] visited;
    float[string] worldX;

    walkTree!TestNode(root, Matrix4x4f.identity, &translate, (n, world, local) {
        visited ~= n.name;
        worldX[n.name] = world.a14;

        return Walk.descend;
    });

    assert(visited == ["root", "a", "a1", "b"], "preorder, children keep their order");
    assert(worldX["root"] == 1 && worldX["a"] == 3 && worldX["a1"] == 7 && worldX["b"] == 4);

    visited = null;

    walkTree!TestNode(root, Matrix4x4f.identity, &translate, (n, world, local) {
        visited ~= n.name;

        return n.name == "a" ? Walk.skip : Walk.descend;
    });

    assert(visited == ["root", "a", "b"], "skip leaves the children out");

    visited = null;

    const result = walkTree!TestNode(root, Matrix4x4f.identity, &translate, (n, world, local) {
        visited ~= n.name;

        return n.name == "a" ? Walk.stop : Walk.descend;
    });

    assert(result == Walk.stop);
    assert(visited == ["root", "a"], "stop ends the walk");
}
