module pukan.vulkan.slist;

import std.container.slist;

struct SimpleSList(T, alias elementDtor = null)
{
    private SList!T list;

    alias ElemType = Elem;

    void insert(T val) { list.insert(val); }
    Elem front() => Elem(list.opSlice);
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
        import std.traits;

        ReturnType!(list.opSlice) val;

        ref getVal(ET = T)() => cast(ET) val.front;
        alias this = getVal;

        void detach() { /* TODO: implement */ }
    }
}
