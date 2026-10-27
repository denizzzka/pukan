module pukan.vulkan.slist;

import std.container.slist;
import std.traits;

struct SimpleSList(T, alias elementDtor = null)
{
    private SList!T list;

    alias ElemType = Elem;

    ~this()
    {
        static if(!is(typeof(elementDtor) == typeof(null)))
        {
            foreach(ref e; list)
                elementDtor(e);
        }
    }

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
            import std.range: take;

            list.linearRemove(oneElemRange.take(1));
        }

        /// Destroys the element if elementDtor is set, then removes it
        void dispose()
        {
            static if(!is(typeof(elementDtor) == typeof(null)))
                elementDtor(getVal);

            detach();
        }
    }
}

private void testElementDtor(ref int value)
{
    value = -1;
}

unittest
{
    SimpleSList!(int, testElementDtor) list;
    list.insert(1);
    list.insert(2);
    list.insert(3);

    auto e = list.front;
    assert(e.getVal == 3);
    e.dispose();

    int[] values;
    foreach (v; list[])
        values ~= v;

    assert(values == [2, 1]);
}
