module pukan.vulkan.slist;

import std.container.slist;
import std.traits;

struct SimpleSList(T, alias elementDtor = null)
{
    private SList!T list;

    alias ElemType = Elem;

    void insert(T val) { list.insert(val); }
    Elem front() => Elem(&list, list.opSlice);
    bool empty() => list.empty;
    auto opSlice() => list.opSlice();
    auto insertOne(void delegate(ref T) dg)
    {
        T val;
        dg(val);
        list.insert(val);

        return front();
    }

    static struct Elem
    {
        private SList!T* list;
        private ReturnType!(list.opSlice) oneElemRange;

        //TODO: rename to payload?
        ref getVal() => oneElemRange.front;
        alias this = getVal;

        void detach()
        {
            //~ list.linearRemove(oneElemRange);
        }
    }
}
