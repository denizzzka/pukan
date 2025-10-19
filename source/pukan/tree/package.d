module pukan.tree;

import std.container.slist;

class Node
{
    debug Node parent;
    SList!(Node) children;

    auto addChildNode()
    {
        auto c = new Node;
        debug c.parent = this;

        children.insert(c);

        return children.opSlice;
    }

    protected void traversal(void delegate(Node) dg)
    {
        dg(this);

        foreach(c; children)
            c.traversal(dg);
    }
}
