module std.experimental.allocator.mmap_allocator;

// MmapAllocator
/**

Allocator (currently defined only for Posix) using $(D $(LUCKY mmap)) and $(D
$(LUCKY munmap)) directly. There is no additional structure: each call to $(D
allocate(s)) issues a call to $(D mmap(null, s, PROT_READ | PROT_WRITE,
MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)), and each call to $(D deallocate(b)) issues
$(D munmap(b.ptr, b.length)). So $(D MmapAllocator) is usually intended for
allocating large chunks to be managed by fine-granular allocators.

*/
struct MmapAllocator
{
    /// The one shared instance.
    static shared MmapAllocator it;

    /**
    Alignment is page-size and hardcoded to 4096 (even though on certain systems
    it could be larger).
    */
    enum size_t alignment = 4096;

    version(Posix)
    {
        /// Allocator API.
        void[] allocate(size_t bytes) shared
        {
            import core.sys.posix.sys.mman;
            if (!bytes) return null;
            version(OSX) import core.sys.osx.sys.mman : MAP_ANON;
            else version(linux) import core.sys.linux.sys.mman : MAP_ANON;
            else version(FreeBSD) import core.sys.freebsd.sys.mman : MAP_ANON;
            else static assert(false, "Add import for MAP_ANON here.");
            auto p = mmap(null, bytes, PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANON, -1, 0);
            if (p is MAP_FAILED) return null;
            return p[0 .. bytes];
        }

        /// Ditto
        bool deallocate(void[] b) shared
        {
            import core.sys.posix.sys.mman : munmap;
            if (b.ptr) munmap(b.ptr, b.length) == 0 || assert(0);
            return true;
        }
    }
    else version(Windows)
    {
        import core.sys.windows.windows;

        // kept to close the mapped memory.
        private static shared(HANDLE) f;

        /// Allocator API.
        void[] allocate(size_t bytes) shared
        {
            if (!bytes) return null;

            uint hiSz, loSz;
            static if (bytes.sizeof == 8)
            {
                loSz = LOWORD(bytes);
                hiSz = HIWORD(bytes);
            }
            else loSz = bytes;

            auto fh = CreateFileMappingA(INVALID_HANDLE_VALUE,
                LPSECURITY_ATTRIBUTES.init, PAGE_READWRITE, hiSz, loSz, null);
            if (fh == INVALID_HANDLE_VALUE) return null;

            auto p = MapViewOfFile(fh, FILE_MAP_ALL_ACCESS, 0u, 0u, bytes);
            if (p == null)
            {
                CloseHandle(fh);
                return null;
            }

            f = cast(typeof(f)) fh;
            return p[0 .. bytes];
        }

        /// Ditto
        bool deallocate(void[] b) shared
        {
            int result = true;
            if (b.ptr)
                result &= UnmapViewOfFile(b.ptr);
            if (f != INVALID_HANDLE_VALUE)
                result &= CloseHandle(cast(HANDLE) f);
            return result != 0;
        }
    }
}

unittest
{
    alias alloc = MmapAllocator.it;
    auto p = alloc.allocate(100);
    assert(p.length == 100);
    alloc.deallocate(p);
}
