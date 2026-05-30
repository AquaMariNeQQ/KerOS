const PAGES_PER_CHUNK = @import("buddy.zig").PAGES_PER_CHUNK;
const MAX_CHUNKS = @import("buddy.zig").MAX_CHUNKS;
const Page = @import("buddy.zig").Page;

pub fn get_page(chunks: *[MAX_CHUNKS]?*Page, phys_addr: u64) ?*Page {
    const real_phys_addr = phys_addr & ~@as(u64, 4095);
    const chunk_idx = real_phys_addr / (PAGES_PER_CHUNK*4096);
    const page_idx = (real_phys_addr / 4096) % PAGES_PER_CHUNK;
    if (chunk_idx >= MAX_CHUNKS) return null;
    const chunk = chunks[@intCast(chunk_idx)];
    if (chunk) |ch| {
        const chunks_from_current: [*]Page = @ptrCast(ch);
        return &chunks_from_current[page_idx];
    } else {
        // println!("RETURNING NULL_MUT() FROM GET_PAGE()!");
        return null;
    }
}

pub fn get_addr_from_page(page: *Page, list: *[MAX_CHUNKS]?*Page) ?*anyopaque {
    const metadata_base = list[page.chunk] orelse return null;
    const base_ptr: [*]Page = @ptrCast(metadata_base);
    const p_ptr: [*]Page = @ptrCast(page);
    const page_idx_in_chunk = p_ptr - base_ptr;
    const chunk_start = page.chunk * PAGES_PER_CHUNK * 4096;
    const page_addr = chunk_start + page_idx_in_chunk * 4096;
    return @ptrFromInt(page_addr);
}

const std = @import("std");
const BuddyAllocator = @import("buddy.zig").BuddyAllocator;
pub const Spinlock = struct {
    lock_value: bool,
    data: BuddyAllocator,

    pub fn lock(self: *Spinlock) *BuddyAllocator {
        while (@atomicRmw(bool, &self.lock_value, .Xchg, true, .acquire)) {
            std.atomic.spinLoopHint();
        }
        return &self.data;
    }

    pub fn unlock(self: *Spinlock) void {
        @atomicStore(bool, self.lock_value, false, .release);
    }
    pub fn new(allocator: BuddyAllocator) Spinlock {
        return .{
            .lock_value = false,
            .data = allocator
        };
    }
};
pub var ALLOCATOR = Spinlock.new(BuddyAllocator.new());
// extern var ALLOCATOR: Spinlock;