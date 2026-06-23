const RwSpinlock = @import("../datastructs/rw_spinlock.zig").RwSpinlock;
const Paging = @import("../arch.zig").Paging;
const ALLOCATOR = @import("memory.zig").ALLOCATOR;

pub const AbstractPageFlags = packed struct {
    writable: bool = false,
    user_accessable: bool = false,
    write_through: bool = false,
    no_cache: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    global: bool = false,
    executable: bool = false,
    padding: u8 = 0
};

pub const MapError = error {
    overlap,
    out_of_memory,
    invalid_alignment,
    page_not_present,
    unexpected_huge_page,
};

pub const AddrSpace = struct {
    root: *anyopaque,
};

const MMIOVMinternal = struct {
    kernel_space: RwSpinlock(AddrSpace),
    last_virt: u64 = 0xFFFFD00000000000,

    pub fn iomap(self: *@This(), phys: u64, size: u64) *anyopaque {
        const aligned = (size + 0xFFF) & ~@as(u64, 0xFFF);
        const virt = self.last_virt;
        self.last_virt += aligned;
        const space = self.kernel_space.writeLock();
        defer self.kernel_space.writeUnlock();
        const alloc = ALLOCATOR.lock();
        defer ALLOCATOR.unlock();
        Paging.mapRange(space.*, virt, phys, aligned, .{.writable = true}, alloc)
            catch @panic("iomap failed, no point in continuing");
        return @ptrFromInt(virt);
    }
    pub fn iounmap(_: *@This(), _: u64) void {
        // todo change from bump to linked list allocator
    }
};
pub var MMIOVMalloc: MMIOVMinternal = undefined;