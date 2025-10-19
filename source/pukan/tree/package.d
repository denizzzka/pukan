module pukan.tree;

import pukan.vulkan.helpers: SimpleSList;
import std.container.slist;

class Node
{
    debug Node parent;
    SimpleSList!Node children;

    protected auto addChildNode(Node c)
    {
        debug c.parent = this;

        children.insert(c);

        return children.front;
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

        Node.children.ElemType addChildNode()
        {
            auto n = new DerrNode;
            return super.addChildNode(n);
        }
    }

    auto root = new DerrNode;
    root.addChildNode();
}
