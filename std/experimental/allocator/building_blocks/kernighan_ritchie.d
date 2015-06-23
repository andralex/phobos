module std.experimental.allocator.building_blocks.kernighan_ritchie;
import std.experimental.allocator.building_blocks.null_allocator;

//debug = KRRegion;
debug(KRRegion) import std.stdio;
version(unittest) import std.conv : text;

// KRRegion
/**
$(D KRRegion) draws inspiration from the $(LINK2
std_experimental_allocator_region.html, region allocation strategy) and also the
$(WEB stackoverflow.com/questions/13159564/explain-this-implementation-of-malloc-from-the-kr-book,
famed allocator) described by Brian Kernighan and Dennis Ritchie in section 8.7
of the book $(WEB amazon.com/exec/obidos/ASIN/0131103628/classicempire, "The C
Programming Language"), Second Edition, Prentice Hall, 1988.

$(H4 `KRRegion` = `Region` + Kernighan-Ritchie Allocator)

Initially, `KRRegion` starts in "region" mode: allocations are served from
the memory chunk in a region fashion. Thus, as long as there is enough memory
left, $(D KRRegion.allocate) has the performance profile of a region allocator.
Deallocation inserts (in $(BIGOH 1) time) the deallocated blocks in an
unstructured freelist, which is not read in region mode.

Once the region cannot serve an $(D allocate) request, $(D KRRegion) switches
to "free list" mode. It sorts the list of previously deallocated blocks by
address and serves allocation requests off that free list. The allocation and
deallocation follow the pattern described by Kernighan and Ritchie.

The recommended use of `KRRegion` is as a $(I region with deallocation). If the
`KRRegion` is dimensioned appropriately, it could often not enter free list
mode during its lifetime. Thus it is as fast as a simple region, whilst
offering deallocation at a small cost. When the region memory is  exhausted,
the previously deallocated memory is still usable, at a performance  cost. If
the region is not excessively large and fragmented, the linear  allocation and
deallocation cost may still be compensated for by the good locality
characteristics.

If the chunk of memory managed is large, it may be desirable to switch
management to free list from the beginning. That way, memory may be used in a
more compact manner than region mode. To force free list mode, call $(D
switchToFreeList) shortly after construction or when deemed appropriate.

The smallest size that can be allocated is two words (16 bytes on 64-bit
systems, 8 bytes on 32-bit systems). This is because the free list management
needs two words (one for the length, the other for the next pointer in the
singly-linked list).

The $(D ParentAllocator) type parameter is the type of the allocator used to
allocate the memory chunk underlying the $(D KRRegion) object. Choosing the
default ($(D NullAllocator)) means the user is responsible for passing a buffer
at construction (and for deallocating it if necessary). Otherwise, $(D KRRegion)
automatically deallocates the buffer during destruction. For that reason, if
$(D ParentAllocator) is not $(D NullAllocator), then $(D KRRegion) is not
copyable.

$(H4 Implementation Details)

In free list mode, $(D KRRegion) embeds a free blocks list onto the chunk of
memory. The free list is circular, coalesced, and sorted by address at all
times. Allocations and deallocations take time proportional to the number of
previously deallocated blocks. (In practice the cost may be lower, e.g. if
memory is deallocated in reverse order of allocation, all operations take
constant time.) Memory utilization is good (small control structure and no
per-allocation overhead). The disadvantages of freelist mode include proneness
to fragmentation, a minimum allocation size of two words, and linear worst-case
allocation and deallocation times.

Similarities of `KRRegion` (in free list mode) with the
Kernighan-Ritchie allocator:

$(UL
$(LI Free blocks have variable size and are linked in a singly-linked list.)
$(LI The freelist is maintained in increasing address order, which makes
coalescing easy.)
$(LI The strategy for finding the next available block is first fit.)
$(LI The free list is circular, with the last node pointing back to the first.)
$(LI Coalescing is carried during deallocation.)
)

Differences from the Kernighan-Ritchie allocator:

$(UL
$(LI Once the chunk is exhausted, the Kernighan-Ritchie allocator allocates
another chunk using operating system primitives. For better composability, $(D
KRRegion) just gets full (returns $(D null) on new allocation requests). The
decision to allocate more blocks is deferred to a higher-level entity. For an
example, see the example below using $(D AllocatorList) in conjunction with $(D
KRRegion).)
$(LI Allocated blocks do not hold a size prefix. This is because in D the size
information is available in client code at deallocation time.)
)

*/
struct KRRegion(ParentAllocator = NullAllocator)
{
    import std.experimental.allocator.common : stateSize, alignedAt, Ternary;
    import std.traits : hasMember;

    private static struct Node
    {
        import std.typecons : tuple, Tuple;

        Node* next;
        size_t size;

        this(this) @disable;

        void[] payload() inout
        {
            return (cast(ubyte*) &this)[0 .. size];
        }

        bool adjacent(in Node* right) const
        {
            assert(right);
            auto p = payload;
            return p.ptr + p.length == right;
        }

        bool coalesce()
        {
            if (!adjacent(next)) return false;
            size += next.size;
            next = next.next;
            return true;
        }

        Tuple!(void[], Node*) allocateHere(size_t bytes)
        {
            assert(bytes >= Node.sizeof);
            assert(bytes % Node.alignof == 0);
            assert(next);
            assert(!adjacent(next));
            if (size < bytes) return typeof(return)();
            assert(size >= bytes);
            immutable leftover = size - bytes;
            if (leftover >= Node.sizeof)
            {
                // There's room for another node
                auto newNode = cast(Node*) ((cast(ubyte*) &this) + bytes);
                newNode.size = leftover;
                newNode.next = next == &this ? newNode : next;
                assert(next);
                return tuple(payload, newNode);
            }
            // No slack space, just return next node
            return tuple(payload, next == &this ? null : next);
        }
    }

    // state {
    /**
    If $(D ParentAllocator) holds state, $(D parent) is a public member of type
    $(D KRRegion). Otherwise, $(D parent) is an $(D alias) for
    `ParentAllocator.instance`.
    */
    static if (stateSize!ParentAllocator) ParentAllocator parent;
    else alias parent = ParentAllocator.instance;
    private void[] payload;
    private Node* root;
    private bool regionMode = true;
    // }

    auto byNodePtr()
    {
        static struct Range
        {
            Node* start, current;
            @property bool empty() { return !current; }
            @property Node* front() { return current; }
            void popFront()
            {
                assert(current && current.next);
                current = current.next;
                if (current == start) current = null;
            }
            @property Range save() { return this; }
        }
        import std.range : isForwardRange;
        static assert(isForwardRange!Range);
        return Range(root, root);
    }

    string toString()
    {
        import std.format : format;
        string s = "KRRegion@";
        s ~= format("%s-%s(0x%s[%s] %s", &this, &this + 1,
            payload.ptr, payload.length,
            regionMode ? "(region)" : "(freelist)");

        Node* lastNode = null;
        if (!regionMode)
        {
            foreach (node; byNodePtr)
            {
                s ~= format(", %sfree(0x%s[%s])",
                    lastNode && lastNode.adjacent(node) ? "+" : "",
                    cast(void*) node, node.size);
                lastNode = node;
            }
        }
        else
        {
            for (auto node = root; node; node = node.next)
            {
                s ~= format(", %sfree(0x%s[%s])",
                    lastNode && lastNode.adjacent(node) ? "+" : "",
                    cast(void*) node, node.size);
                lastNode = node;
            }
        }

        s ~= ')';
        return s;
    }

    private void assertValid(string s)
    {
        assert(!regionMode);
        if (!payload.ptr)
        {
            assert(!root, s);
            return;
        }
        if (!root)
        {
            return;
        }
        assert(root >= payload.ptr, s);
        assert(root < payload.ptr + payload.length, s);

        // Check that the list terminates
        size_t n;
        foreach (node; byNodePtr)
        {
            assert(node.next);
            assert(!node.adjacent(node.next));
            assert(n++ < payload.length / Node.sizeof, s);
        }
    }

    private Node* sortFreelist(Node* root)
    {
        // Find a monotonic run
        auto last = root;
        for (;;)
        {
            if (!last.next) return root;
            if (last > last.next) break;
            assert(last < last.next);
            last = last.next;
        }
        auto tail = last.next;
        last.next = null;
        tail = sortFreelist(tail);
        return merge(root, tail);
    }

    private Node* merge(Node* left, Node* right)
    {
        assert(left != right);
        if (!left) return right;
        if (!right) return left;
        if (left < right)
        {
            auto result = left;
            result.next = merge(left.next, right);
            return result;
        }
        auto result = right;
        result.next = merge(left, right.next);
        return result;
    }

    private void coalesceAndMakeCircular()
    {
        for (auto n = root;;)
        {
            assert(!n.next || n < n.next);
            if (!n.next)
            {
                // Convert to circular
                n.next = root;
                break;
            }
            if (n.coalesce) continue; // possibly another coalesce
            n = n.next;
        }
    }

    /**
    Create a $(D KRRegion). If $(D ParentAllocator) is not $(D NullAllocator),
    $(D KRRegion)'s destructor will call $(D parent.deallocate).

    Params:
    b = Block of memory to serve as support for the allocator. Memory must be
    larger than two words and word-aligned.
    n = Capacity desired. This constructor is defined only if $(D
    ParentAllocator) is not $(D NullAllocator).
    */
    this(void[] b)
    {
        if (b.length < Node.sizeof)
        {
            // Init as empty
            assert(root is null);
            assert(payload is null);
            return;
        }
        assert(b.length >= Node.sizeof);
        assert(b.ptr.alignedAt(Node.alignof));
        assert(b.length >= 2 * Node.sizeof);
        payload = b;
        root = cast(Node*) b.ptr;
        // Initialize the free list with all list
        assert(regionMode);
        root.next = null;
        root.size = b.length;
        debug(KRRegion) writefln("KRRegion@%s: init with %s[%s]", &this,
            b.ptr, b.length);
    }

    /// Ditto
    static if (!is(ParentAllocator == NullAllocator))
    this(size_t n)
    {
        assert(n > Node.sizeof);
        this(parent.allocate(n));
    }

    /// Ditto
    static if (!is(ParentAllocator == NullAllocator)
        && hasMember!(ParentAllocator, "deallocate"))
    ~this()
    {
        parent.deallocate(payload);
    }

    /**
    Forces free list mode. If already in free list mode, does nothing.
    Otherwise, sorts the free list accumulated so far and switches strategy for
    future allocations to KR style.
    */
    void switchToFreeList()
    {
        if (!regionMode) return;
        regionMode = false;
        if (!root) return;
        root = sortFreelist(root);
        coalesceAndMakeCircular;
    }

    /*
    Noncopyable
    */
    @disable this(this);

    /**
    Word-level alignment.
    */
    enum alignment = Node.alignof;

    /**
    Allocates $(D n) bytes. Allocation searches the list of available blocks
    until a free block with $(D n) or more bytes is found (first fit strategy).
    The block is split (if larger) and returned.

    Params: n = number of bytes to _allocate

    Returns: A word-aligned buffer of $(D n) bytes, or $(D null).
    */
    void[] allocate(size_t n)
    {
        if (!n || !root) return null;
        const actualBytes = goodAllocSize(n);

        // Try the region first
        if (regionMode)
        {
            // Only look at the head of the freelist
            if (root.size >= actualBytes)
            {
                // Enough room for allocation
                void* result = root;
                immutable balance = root.size - actualBytes;
                if (balance >= Node.sizeof)
                {
                    auto newRoot = cast(Node*) (result + actualBytes);
                    newRoot.next = root.next;
                    newRoot.size = balance;
                    root = newRoot;
                }
                else
                {
                    root = null;
                    switchToFreeList;
                }
                return result[0 .. n];
            }
            // Not enough memory, switch to freelist mode and fall through
            switchToFreeList;
        }

        // Try to allocate from next after the iterating node
        for (auto pnode = root;;)
        {
            assert(!pnode.adjacent(pnode.next));
            auto k = pnode.next.allocateHere(actualBytes);
            if (k[0] !is null)
            {
                // awes
                assert(k[0].length >= n);
                if (root == pnode.next) root = k[1];
                pnode.next = k[1];
                return k[0][0 .. n];
            }
            pnode = pnode.next;
            if (pnode == root) break;
        }
        return null;
    }

    /**
    Deallocates $(D b), which is assumed to have been previously allocated with
    this allocator. Deallocation performs a linear search in the free list to
    preserve its sorting order. It follows that blocks with higher addresses in
    allocators with many free blocks are slower to deallocate.

    Params: b = block to be deallocated
    */
    bool deallocate(void[] b)
    {
        debug(KRRegion) writefln("KRRegion@%s: deallocate(%s[%s])", &this,
            b.ptr, b.length);
        if (!b.ptr) return true;
        assert(owns(b) == Ternary.yes);
        assert(b.ptr.alignedAt(Node.alignof));

        // Insert back in the freelist, keeping it sorted by address. Do not
        // coalesce at this time. Instead, do it lazily during allocation.
        auto n = cast(Node*) b.ptr;
        n.size = goodAllocSize(b.length);

        if (regionMode)
        {
            assert(root);
            // Insert right after root
            n.next = root.next;
            root.next = n;
            return true;
        }

        if (!root)
        {
            // What a sight for sore eyes
            root = n;
            root.next = root;
            return true;
        }

        version(assert) foreach (test; byNodePtr)
        {
            assert(test != n);
        }
        // Linear search
        auto pnode = root;
        do
        {
            assert(pnode && pnode.next);
            assert(pnode != n);
            assert(pnode.next != n);
            if (pnode < pnode.next)
            {
                if (pnode >= n || n >= pnode.next) continue;
                // Insert in between pnode and pnode.next
                n.next = pnode.next;
                pnode.next = n;
                n.coalesce;
                pnode.coalesce;
                root = pnode;
                return true;
            }
            else if (pnode < n)
            {
                // Insert at the end of the list
                n.next = pnode.next;
                pnode.next = n;
                pnode.coalesce;
                root = pnode;
                return true;
            }
            else if (n < pnode.next)
            {
                // Insert at the front of the list
                n.next = pnode.next;
                pnode.next = n;
                n.coalesce;
                root = n;
                return true;
            }
        }
        while ((pnode = pnode.next) != root);
        assert(0, "Wrong parameter passed to deallocate");
    }

    /**
    Allocates all memory available to this allocator. If the allocator is empty,
    returns the entire available block of memory. Otherwise, it still performs
    a best-effort allocation: if there is no fragmentation (e.g. $(D allocate)
    has been used but not $(D deallocate)), allocates and returns the only
    available block of memory.

    The operation takes time proportional to the number of adjacent free blocks
    at the front of the free list. These blocks get coalesced, whether
    $(D allocateAll) succeeds or fails due to fragmentation.
    */
    void[] allocateAll()
    {
        //debug(KRRegion) assertValid("allocateAll");
        //debug(KRRegion) scope(exit) assertValid("allocateAll");
        if (regionMode) switchToFreeList;
        if (root && root.next == root)
            return allocate(root.size);
        return null;
    }

    ///
    unittest
    {
        import std.experimental.allocator.gc_allocator : GCAllocator;
        auto alloc = KRRegion!GCAllocator(1024 * 64);
        const b1 = alloc.allocate(2048);
        assert(b1.length == 2048);
        const b2 = alloc.allocateAll;
        assert(b2.length == 1024 * 62);
    }

    /**
    Deallocates all memory currently allocated, making the allocator ready for
    other allocations. This is a $(BIGOH 1) operation.
    */
    bool deallocateAll()
    {
        debug(KRRegion) assertValid("deallocateAll");
        debug(KRRegion) scope(exit) assertValid("deallocateAll");
        root = cast(Node*) payload.ptr;
        // Initialize the free list with all list
        if (root)
        {
            root.next = root;
            root.size = payload.length;
        }
        return true;
    }

    /**
    Checks whether the allocator is responsible for the allocation of $(D b).
    It does a simple $(BIGOH 1) range check. $(D b) should be a buffer either
    allocated with $(D this) or obtained through other means.
    */
    Ternary owns(void[] b)
    {
        debug(KRRegion) assertValid("owns");
        debug(KRRegion) scope(exit) assertValid("owns");
        return Ternary(b.ptr >= payload.ptr
            && b.ptr < payload.ptr + payload.length);
    }

    /**
    Adjusts $(D n) to a size suitable for allocation (two words or larger,
    word-aligned).
    */
    static size_t goodAllocSize(size_t n)
    {
        import std.experimental.allocator.common : roundUpToMultipleOf;
        return n <= Node.sizeof
            ? Node.sizeof : n.roundUpToMultipleOf(alignment);
    }

    /**
    Returns: `Ternary.yes` if the allocator is empty, `Ternary.no` otherwise.
    Never returns `Ternary.unknown`.
    */
    Ternary empty()
    {
        return Ternary(root && root.size == payload.length);
    }
}

/**
$(D KRRegion) is preferable to $(D Region) as a front for a general-purpose
allocator if $(D deallocate) is needed, yet the actual deallocation traffic is
relatively low. The example below shows a $(D KRRegion) using stack storage
fronting the GC allocator.
*/
unittest
{
    import std.experimental.allocator.gc_allocator : GCAllocator;
    import std.experimental.allocator.building_blocks.fallback_allocator
        : fallbackAllocator;
    import std.experimental.allocator.common : Ternary;
    // KRRegion fronting a general-purpose allocator
    ubyte[1024 * 128] buf;
    auto alloc = fallbackAllocator(KRRegion!()(buf), GCAllocator.instance);
    auto b = alloc.allocate(100);
    assert(b.length == 100);
    assert(alloc.primary.owns(b) == Ternary.yes);
}

/**
The code below defines a scalable allocator consisting of 1 MB (or larger)
blocks fetched from the garbage-collected heap. Each block is organized as a
KR-style heap. More blocks are allocated and freed on a need basis.

This is the closest example to the allocator introduced in the K$(AMP)R book.
It should perform slightly better because instead of searching through one
large free list, it searches through several shorter lists in LRU order. Also,
it actually returns memory to the operating system when possible.
*/
unittest
{
    import std.algorithm : max;
    import std.experimental.allocator.gc_allocator : GCAllocator;
    import std.experimental.allocator.mmap_allocator : MmapAllocator;
    import std.experimental.allocator.building_blocks.allocator_list
        : AllocatorList;
    AllocatorList!(n => KRRegion!MmapAllocator(max(n * 16, 1024 * 1024))) alloc;
}

unittest
{
    import std.algorithm : max;
    import std.experimental.allocator.gc_allocator : GCAllocator;
    import   std.experimental.allocator.common : Ternary;
    import std.experimental.allocator.mallocator : Mallocator;
    import std.experimental.allocator.building_blocks.allocator_list
        : AllocatorList;
    /*
    Create a scalable allocator consisting of 1 MB (or larger) blocks fetched
    from the garbage-collected heap. Each block is organized as a KR-style
    heap. More blocks are allocated and freed on a need basis.
    */
    AllocatorList!(n => KRRegion!Mallocator(max(n * 16, 1024 * 1024)),
        NullAllocator) alloc;
    void[][50] array;
    foreach (i; 0 .. array.length)
    {
        auto length = i * 100_000 + 1;
        array[i] = alloc.allocate(length);
        assert(array[i].ptr);
        assert(array[i].length == length);
    }
    import std.random : randomShuffle;
    randomShuffle(array[]);
    foreach (i; 0 .. array.length)
    {
        assert(array[i].ptr);
        assert(alloc.owns(array[i]) == Ternary.yes);
        alloc.deallocate(array[i]);
    }
}

unittest
{
    import std.algorithm : max;
    import std.experimental.allocator.gc_allocator : GCAllocator;
    import std.experimental.allocator.common : Ternary;
    import std.experimental.allocator.mmap_allocator : MmapAllocator;
    import std.experimental.allocator.building_blocks.allocator_list
        : AllocatorList;
    /*
    Create a scalable allocator consisting of 1 MB (or larger) blocks fetched
    from the garbage-collected heap. Each block is organized as a KR-style
    heap. More blocks are allocated and freed on a need basis.
    */
    AllocatorList!((n) {
        auto result = KRRegion!MmapAllocator(max(n * 2, 1024 * 1024));
        return result;
    }) alloc;
    void[][490] array;
    foreach (i; 0 .. array.length)
    {
        auto length = i * 10_000 + 1;
        array[i] = alloc.allocate(length);
        assert(array[i].ptr);
        foreach (j; 0 .. i)
        {
            assert(array[i].ptr != array[j].ptr);
        }
        assert(array[i].length == length);
    }
    import std.random : randomShuffle;
    randomShuffle(array[]);
    foreach (i; 0 .. array.length)
    {
        assert(alloc.owns(array[i]) == Ternary.yes);
        alloc.deallocate(array[i]);
    }
}

unittest
{
    import std.experimental.allocator.gc_allocator : GCAllocator;
    import std.experimental.allocator.building_blocks.allocator_list
        : AllocatorList;
    import std.algorithm : max;
    import std.experimental.allocator.common : testAllocator;
    testAllocator!(() => AllocatorList!(
        n => KRRegion!GCAllocator(max(n * 16, 1024 * 1024)))());
}

unittest
{
    import std.experimental.allocator.gc_allocator : GCAllocator;

    auto alloc = KRRegion!GCAllocator(1024 * 1024);

    void[][] array;
    foreach (i; 1 .. 4)
    {
        array ~= alloc.allocate(i);
        assert(array[$ - 1].length == i);
    }
    alloc.deallocate(array[1]);
    alloc.deallocate(array[0]);
    alloc.deallocate(array[2]);
    assert(alloc.allocateAll().length == 1024 * 1024);
}

unittest
{
    import std.experimental.allocator.gc_allocator : GCAllocator;
    import std.experimental.allocator.common : Ternary;
    auto alloc = KRRegion!()(GCAllocator.instance.allocate(1024 * 1024));
    const store = alloc.allocate(KRRegion!().sizeof);
    auto p = cast(KRRegion!()* ) store.ptr;
    import std.conv : emplace;
    import std.algorithm : move;
    import core.stdc.string : memcpy;

    memcpy(p, &alloc, alloc.sizeof);
    emplace(&alloc);

    void[][100] array;
    foreach (i; 0 .. array.length)
    {
        auto length = 100 * i + 1;
        array[i] = p.allocate(length);
        assert(array[i].length == length, text(array[i].length));
        assert(p.owns(array[i]) == Ternary.yes);
    }
    import std.random : randomShuffle;
    randomShuffle(array[]);
    foreach (i; 0 .. array.length)
    {
        assert(p.owns(array[i]) == Ternary.yes);
        p.deallocate(array[i]);
    }
    auto b = p.allocateAll();
    assert(b.length == 1024 * 1024 - KRRegion!().sizeof, text(b.length));
}

unittest
{
    import std.experimental.allocator.gc_allocator : GCAllocator;
    auto alloc = KRRegion!()(GCAllocator.instance.allocate(1024 * 1024));
    auto p = alloc.allocateAll();
    assert(p.length == 1024 * 1024);
    alloc.deallocateAll();
    p = alloc.allocateAll();
    assert(p.length == 1024 * 1024);
}
