module std.experimental.allocator.auto_deallocator;

import std.experimental.allocator.common;
import std.experimental.allocator.null_allocator;

/**

$(D AutoDeallocator) delegates all allocation requests to $(D ParentAllocator).
When destroyed, the $(D AutoDeallocator) object automatically calls $(D
deallocate) for all memory allocated through its lifetime. (The $(D
deallocateAll) function is also implemented with the same semantics.)

$(D deallocate) is also supported, which is where most implementation effort
and overhead of $(D AutoDeallocator) go. If $(D deallocate) is not needed, a
simpler design combining $(D AllocatorList) with $(D Region) is recommended.

Example:
---
import std.experimental.allocator.mallocator;
AutoDeallocator!Mallocator alloc;
assert(alloc.empty);
auto b = alloc.allocate(10);
assert(b.length == 10);
assert(!alloc.empty);
// The destructor of alloc will free all memory
---
*/
struct AutoDeallocator(ParentAllocator)
{
    unittest
    {
        testAllocator!(() => AutoDeallocator());
    }

    import std.experimental.allocator.affix_allocator;
    import std.traits : hasMember;

    private struct Node
    {
        Node* prev;
        Node* next;
        size_t length;
    }

    alias Allocator = AffixAllocator!(ParentAllocator, Node);

    // state {
    /**
    If $(D ParentAllocator) is stateful, $(D parent) is a property giving access
    to an $(D AffixAllocator!ParentAllocator). Otherwise, $(D parent) is an alias for $(D AffixAllocator!ParentAllocator.it).
    */
    static if (stateSize!ParentAllocator)
    {
        Allocator parent;
    }
    else
    {
        alias parent = Allocator.it;
    }
    Node* root;
    // }

    /**
    $(D AutoDeallocator) is not copyable.
    */
    @disable this(this);

    /**
    $(D AutoDeallocator)'s destructor releases all memory allocated during its
    lifetime.
    */
    ~this()
    {
        deallocateAll;
    }

    /// Alignment offered
    enum alignment = ParentAllocator.alignment;

    /**
    Forwards to $(D parent.goodAllocSize) (which accounts for the management
    overhead).
    */
    size_t goodAllocSize(size_t n)
    {
        return parent.goodAllocSize(n);
    }

    /**
    Allocates memory. For management it actually allocates extra memory from
    the parent.
    */
    void[] allocate(size_t n)
    {
        auto b = parent.allocate(n);
        if (!b.ptr) return b;
        Node* toInsert = & parent.prefix(b);
        toInsert.prev = null;
        toInsert.next = root;
        toInsert.length = n;
        root = toInsert;
        return b;
    }

    /**
    Forwards to $(D parent.expand(b, delta)).
    */
    static if (hasMember!(Allocator, "expand"))
    bool expand(ref void[] b, size_t delta)
    {
        auto result = parent.expand(b, delta);
        if (result && b.ptr)
        {
            parent.prefix(b).length = b.length;
        }
        return result;
    }

    /**
    Reallocates $(D b) to new size $(D s).
    */
    bool reallocate(ref void[] b, size_t s)
    {
        // Remove from list
        if (b.ptr)
        {
            Node* n = & parent.prefix(b);
            if (n.prev) n.prev.next = n.next;
            else root = n.next;
            if (n.next) n.next.prev = n.prev;
        }
        auto result = parent.reallocate(b, s);
        // Add back to list
        if (b.ptr)
        {
            Node* n = & parent.prefix(b);
            n.prev = null;
            n.next = root;
            n.length = s;
            root = n;
        }
        return result;
    }

    /**
    Forwards to $(D parent.owns(b)).
    */
    static if (hasMember!(Allocator, "owns"))
    bool owns(void[] b)
    {
        return parent.owns(b);
    }

    /**
    Deallocates $(D b).
    */
    static if (hasMember!(Allocator, "deallocate"))
    void deallocate(void[] b)
    {
        // Remove from list
        if (b.ptr)
        {
            Node* n = & parent.prefix(b);
            if (n.prev) n.prev.next = n.next;
            else root = n.next;
            if (n.next) n.next.prev = n.prev;
        }
        parent.deallocate(b);
    }

    /**
    Deallocates all memory allocated.
    */
    void deallocateAll()
    {
        for (auto n = root; n; )
        {
            void* p = n + 1;
            auto length = n.length;
            n = n.next;
            parent.deallocate(p[0 .. length]);
        }
        root = null;
    }

    /**
    Returns $(D true) if this allocator is not responsible for any memory.
    */
    bool empty() const
    {
        return root is null;
    }
}

///
unittest
{
    import std.experimental.allocator.mallocator;
    AutoDeallocator!Mallocator alloc;
    assert(alloc.empty);
    auto b = alloc.allocate(10);
    assert(b.length == 10);
    assert(!alloc.empty);
}

unittest
{
    import std.experimental.allocator.gc_allocator;
    testAllocator!(() => AutoDeallocator!GCAllocator());
}
