const IntrusiveList = @import("../../datastructs/intrusive_linked_list.zig").IntrusiveList;
const IntrusiveNode = @import("../../datastructs/intrusive_linked_list.zig").IntrusiveNode;
const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
pub const MAX_CHUNKS: usize = 4096; // 1TB ram max
pub const BOOT_MAPPING_SIZE: usize = 1024*1024*1024; // 1GB ram max
pub const BUDDY_LEVELS: usize = 11; // 1TB ram max
pub const PAGES_PER_CHUNK: usize = 131072; // 512MB
const MemoryRegion = @import("../memory.zig").MemoryRegion;
const MemoryRegionKind = @import("../memory.zig").MemoryRegionKind;
const toVirt = @import("../../utils.zig").toVirt;
const get_page = @import("utils.zig").get_page;
const get_addr_from_page = @import("utils.zig").get_addr_from_page;
const AllocationSize = @import("../memory.zig").AllocationSize;

pub const Page = struct {
    /// List for buddy, sometimes - for other things.
    list_node: IntrusiveNode(Page),
// Состояние страницы
    // Normally - 0x4B334F53
    magic: if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) u32 else void,
    /// Flags for allocator ONLY
    flags: AllocatorPageFlags,
    /// 1 << order + 12 = size in bytes
    order: u8,
    /// CPU ID; If isn't owned by CPU - most likely 0x00, but you should look for flag NoOwner in flags
    owner_id: u8,
    /// How many objects are right now on this page. Nothing about the size and max amount of objects on this page will be provided here
    usage: u16,
    /// Which chunk (out of 4096 max) it is in
    chunk: u16,
    /// Free list for SLUB
    free_list_head: ?*u64,

    pub fn check_magic(self: *const @This()) bool {
        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            return self.magic == 0x4B334F53;
        }
        return true; // В релизе проверки всегда успешны
    }

    pub fn set_magic(self: *@This()) void {
        if (comptime builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            self.magic = 0x4B334F53;
        }
    }
};

pub const AllocatorPageFlags = packed struct(u16) {
    is_free: bool,
    no_owner: bool,
    _padding: u14 = 0,
};


pub const BuddyAllocator = struct {
    free_lists: [BUDDY_LEVELS]IntrusiveList(Page),
    chunks: [MAX_CHUNKS]?*Page,
    _total_pages: usize,

    const Self = @This();
    pub fn get_chunks_ptr(self: *Self) *const [MAX_CHUNKS]?*Page {
        return &self.chunks;
    }
    pub fn add_region(self: *Self, region: MemoryRegion) AllocatorError!void {
        if (region.kind != .usable) {
            return AllocatorError.UnusableRegionPassed;
        }
        var reg_ptr = (region.start + @as(u64, 4095)) & ~@as(u64, 4095);
        const end = region.end & ~@as(u64, 4095);

        while (reg_ptr < end) {
            // 1. Считаем align_order
            const align_order = @as(i64, @intCast(@ctz(reg_ptr))) - 12;
            const safe_align_order: u64 = if (align_order < 0) 0 else @intCast(align_order);

            // 2. Считаем distance_order (безопасный ilog2)
            const clz_val = @clz(end - reg_ptr);
            const ilog2_val = @as(i64, 63) - @as(i64, @intCast(clz_val));
            const distance_order = ilog2_val - 12;
            const safe_distance_order: u64 = if (distance_order < 0) 0 else @intCast(distance_order);

            // 3. Выбираем минимальный order (замена Rust-овскому min().min(10))
            var order = if (safe_distance_order < safe_align_order) safe_distance_order else safe_align_order;
            if (order > 10) order = 10;
            const pageptr: *anyopaque = @ptrFromInt(reg_ptr);
            // 4. Работаем со страницей
            const page = get_page(&self.chunks, pageptr) orelse return AllocatorError.UninitializedMetadata;

            page.order = @intCast(order);
            page.set_magic();
            page.owner_id = 0;

            // Здесь используем синтаксис Zig для флагов (предполагая, что это обычные маски)
            page.flags = .{.is_free = true, .no_owner = true };

            // Вставляем в список
            self.free_lists[order].push_front(page);

            // 5. Инкремент указателя (явный u64 сдвиг)
            reg_ptr += @as(u64, 1) << @intCast(order + 12);
        }
    }
    pub fn new() Self {
        return .{
            .free_lists = blk: {
                const ilist = IntrusiveList(Page);
                var lists: [BUDDY_LEVELS]ilist = undefined;
                for (&lists) |*list| {
                    list.* = ilist.init();
                }
                break :blk lists;
            },
            .chunks = std.mem.zeroes([MAX_CHUNKS]?*Page),
            ._total_pages = 0,
        };
    }
    pub fn alloc(self: *Self, order: AllocationSize) ?*anyopaque {
        assert(@intFromEnum(order) >= @intFromEnum(AllocationSize._4KB));
        for (order.to_buddy_size()..AllocationSize._4MB.to_buddy_size() + 1) |current_order | {
            if (!self.free_lists[current_order].isEmpty()) {
                const page: *Page = self.free_lists[current_order].pop_front() orelse @panic("hell 277");
                std.debug.assert(page.check_magic());
                if (page.flags.no_owner) {
                    var split_order = @as(i32, @intCast(current_order)) - 1;
                    const end_order = @as(i32, order.to_buddy_size());
                    while (split_order >= end_order) : (split_order -= 1) {
                        const u_split = @as(usize, @intCast(split_order));
                        const base_slice: [*]Page = @ptrCast(page);
                        const sec_page = &base_slice[@as(usize, 1) << @intCast(u_split)];
                        sec_page.order = @intCast(u_split);
                        sec_page.flags = .{.no_owner = true, .is_free = true};
                        sec_page.set_magic();
                        self.free_lists[u_split].push_back(sec_page);
                    }
                    page.flags = .{.no_owner = false, .is_free = false};
                    page.order = @intCast(order.to_buddy_size());
                    return get_addr_from_page(page, &self.chunks);
                }
            }
        }
        return null;
    }
    pub fn dealloc(self: *Self, addr: ?*anyopaque, size: AllocationSize) void {
        if (addr) |existing_addr| {
            // get the first block
            assert(@intFromEnum(size) >= @intFromEnum(AllocationSize._4KB));
            var current_pfn = @intFromPtr(existing_addr) / 4096;
            const order = size.to_buddy_size();
            var final_order = order;
            for (order..AllocationSize._4MB.to_buddy_size()) |current_order_us| {
                // Сразу после получения buddy_ptr:
                const current_order: u8 = @intCast(current_order_us);
                const buddy_pfn = current_pfn ^ (@as(u64 ,1) << @intCast(current_order));
                const buddy_ptr: *Page = get_page(&self.chunks, buddy_pfn * 4096) orelse break;
                assert(buddy_ptr.check_magic());
                if (buddy_ptr.flags.is_free and buddy_ptr.flags.no_owner and buddy_ptr.order == current_order) {
                    self.free_lists[current_order].remove(buddy_ptr);
                    const no_owner = buddy_ptr.flags.no_owner;
                    buddy_ptr.flags = .{.is_free = false, .no_owner = no_owner};
                    current_pfn &= ~(@as(u64, 1) << @intCast(current_order));
                    final_order = current_order + @as(u8, 1);
                } else {
                    break;
                }
            }
            const final_page_ptr: *Page = get_page(&self.chunks,current_pfn * 4096) orelse return;
            final_page_ptr.flags = .{ .is_free = true, .no_owner = true };
            final_page_ptr.order = final_order;
            final_page_ptr.set_magic();
            self.free_lists[final_order].push_front(final_page_ptr);
        }
    }
};

pub const AllocatorError = error {
    UnusableRegionPassed,
    UninitializedMetadata
};


pub fn add_boot_regions(allocator: *BuddyAllocator, regions: *[64]?MemoryRegion) void {
    const metadata_size = @sizeOf(Page) * PAGES_PER_CHUNK;
    for (regions) |*region| {
        if (region.*) |*reg| {
            if (reg.start < BOOT_MAPPING_SIZE and reg.kind == .usable) {
                if (reg.end <= reg.start) { @panic("Region without any space! WTH?"); }
                if ((reg.end - reg.start) > (metadata_size * 2)) {
                    const start = (reg.start + 4095) & ~@as(u64, 4095);
                    const page1: [*]Page = @ptrCast(@alignCast(toVirt(@ptrFromInt(start))));
                    @memset(page1[0..PAGES_PER_CHUNK], std.mem.zeroes(Page));
                    const page2: [*]Page = @ptrCast(@alignCast(toVirt(@ptrFromInt(start + metadata_size))));
                    @memset(page2[0..PAGES_PER_CHUNK], std.mem.zeroes(Page));
                    var printed = false;
                    for (0..PAGES_PER_CHUNK) |offset| {
                        const p1 = &page1[offset];
                        const p2 = &page2[offset];
                        p1.flags = .{.no_owner = true, .is_free = false};
                        p2.flags = .{.no_owner = true, .is_free = false};
                        p1.chunk = 0;
                        p2.chunk = 1;
                        if (allocator.free_lists[1].head != null and !printed) {
                            printed = true;
                        }
                        p2.set_magic();
                        p1.set_magic();
                    }
                    const chunk_size = @as(u64, PAGES_PER_CHUNK * 4096);
                    const chunk1_idx = @as(usize, start / chunk_size);
                    const chunk2_idx = chunk1_idx + 1;
                    allocator.chunks[chunk1_idx] = &page1[0];
                    allocator.chunks[chunk2_idx] = &page2[0];
                    region.* = MemoryRegion {
                        .start = start + (metadata_size * 2),
                        .end = reg.end,
                        .kind = .usable
                    };
                    break;
                }
            }
        }
    }
    for (regions) |*region| {
        if (region.*) |*reg| {
            if (reg.start < BOOT_MAPPING_SIZE and reg.kind == .usable) {
                if (reg.end <= reg.start) { @panic("Region without any space! WTH?"); }
                if (allocator.add_region(MemoryRegion {
                    .start = reg.start,
                    .end = @min(reg.end, BOOT_MAPPING_SIZE),
                    .kind = .usable,
                })) |_| {
                    if (reg.end > BOOT_MAPPING_SIZE) {

                        region.* = MemoryRegion {
                            .start = BOOT_MAPPING_SIZE,
                            .end = reg.end,
                            .kind = .usable,
                        };
                    } else {
                        region.* = null;
                    }
                }

                else |_| {
                    @panic("hell 311");
                    // println("{}", &msg);
                }
            }
        }
    }

}



pub fn add_other_regions(allocator: *BuddyAllocator, regions: *[64]?MemoryRegion) void {
    var needed_chunks: [MAX_CHUNKS]bool = blk: {
        var chunks: [MAX_CHUNKS]bool = undefined;
        for (&chunks) |*c| {
            c.* = false;
        }
        break :blk chunks;
    };
    for (regions) |*region| {
        if (region.*) |*reg| {
            if (reg.kind == .usable) {
                if (reg.end <= reg.start) { @panic("Region without any space! WTH?"); }
                const st_chunk = reg.start / (4096 * PAGES_PER_CHUNK);
                const end_chunk = (reg.end - 1) / (4096 * PAGES_PER_CHUNK);
                for (st_chunk..end_chunk + 1) |chunk| {
                    needed_chunks[chunk] = true;
                }
            }
        }
    }
    const metadata_size = @sizeOf(Page) * PAGES_PER_CHUNK;
    for (&needed_chunks, 0..) |*need_chunk, chunk_idx| {
        if (!need_chunk.*) { continue; }

        for (regions) |*region| {
            if (region.*) |*reg| {
                if (reg.end - reg.start >= metadata_size and reg.kind == .usable) {
                const virt_addr: [*]Page = @ptrCast(@alignCast(toVirt(@ptrFromInt(reg.start))));
                const nullpage = Page {
                    .list_node = .{.next = null, .prev = null},
                    .magic = 0,
                    .flags = .{.is_free = false, .no_owner = false},
                    .order = 0,
                    .owner_id = 0,
                    .usage = 0,
                    .chunk = 0,
                    .free_list_head = null,

                };
                @memset(virt_addr[0..PAGES_PER_CHUNK], nullpage);
                for (1..PAGES_PER_CHUNK) |offset | {
                    const page = &virt_addr[offset];
                    page.chunk = @intCast(chunk_idx);
                    page.set_magic();
                    page.flags = .{.no_owner = true, .is_free = false};
                }
                allocator.chunks[chunk_idx] = @ptrCast(virt_addr);
                virt_addr[0].flags = .{.is_free = true, .no_owner = true};
                virt_addr[0].chunk = @intCast(chunk_idx);
                virt_addr[0].set_magic();
                // "Откусываем"
                reg.start += @intCast(metadata_size);
                need_chunk.* = false; // Потребность закрыта
                break; // Переходим к следующему chunk_idx
                }
            }
        }
    }
    const missing_chunk = blk: {
        for (needed_chunks) |chunk| {
            if (chunk) break :blk true;
        }
        break :blk false;
    };
    if (missing_chunk) @panic("Chunk metadata not initialized! WHERE THE FUCK IS ALL THE PLACE????");
    for (regions) |*region| {
        if (region.*) |*reg| {
            if (reg.kind == .usable) {
                allocator.add_region(reg.*) catch {
                    @panic("hell 627");
                    // std.debug.print("Failed to add region: {}\n", .{err});
                };
            }
        }
    }
}
