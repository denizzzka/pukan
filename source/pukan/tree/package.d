module pukan.tree;

import pukan.vulkan.helpers: SimpleSList;
import std.container.slist;
import std.traits;

class Node
{
    debug Node parent;
    SList!Node children;

    alias RT = ReturnType!(children.opSlice);

    protected RT addChildNode(Node c)
    {
        debug c.parent = this;

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
