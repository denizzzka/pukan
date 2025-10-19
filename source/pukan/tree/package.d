module pukan.tree;

import pukan.vulkan.helpers: SimpleSList;
import std.container.slist;

class Node
{
    debug Node parent;
    SimpleSList!Node children;

    auto addChildNode()
    {
        auto c = new Node;
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
