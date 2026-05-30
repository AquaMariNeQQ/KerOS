//! const shared = @import("../../../../shared/src/shared.zig");
const IntrusiveList = @import("intrusive_linked_list.zig").IntrusiveList;
const IntrusiveNode = @import("intrusive_linked_list.zig").IntrusiveNode;
// const MemoryRegion = shared.MemoryRegion;
// const MemoryRegionKind = shared.MemoryRegionKind;
const builtin = @import("builtin");
const math = @import("std").math;
const std = @import("std");
const assert = std.debug.assert;
pub const MAX_CHUNKS: usize = 4096; // 1TB ram max
pub const BOOT_MAPPING_SIZE: usize = 1024*1024*1024; // 1TB ram max
pub const BUDDY_LEVELS: usize = 11; // 1TB ram max
pub const PAGES_PER_CHUNK: usize = 131072; // 512MB


pub const MemoryRegionKind = enum {
    /// Свободная память, которую Buddy может забрать себе
    Usable,
    /// Зарезервировано железом (ACPI, BIOS, IO) — НЕ ТРОГАТЬ
    Reserved,
    /// Здесь лежит само ядро (уже занято)
    Kernel,
    /// Здесь лежат данные загрузчика (Multiboot/DTB)
    /// После инициализации это можно будет освободить
    BootloaderData,
    /// Дефектная память
    BadMemory,

};


pub const MemoryRegion = struct {
    start: u64,
    end: u64,
    kind: MemoryRegionKind,
    pub fn size(self: @This()) usize {
        return @as(usize, (self.end-self.start));
    }
};


pub const BootInfo = struct {
    /// Массив регионов. 64 должно хватить даже для фрагментированных систем.
    regions: [64]MemoryRegion = undefined,
    regions_count: usize = 0,
    /// Общий объем найденной памяти (для статистики)
    total_memory_bytes: u64 = 0,
    /// Информация для графического вывода (чтобы сразу видеть Panic)
    framebuffer: ?*FramebufferInfo = null,
    /// Адрес структуры ACPI RSDP (на x86) или Device Tree (на ARM)
    /// Это "корень" для поиска всего железа (таймеры, прерывания, PCI)
    platform_config_ptr: *anyopaque = null,
    /// Командная строка ядра (например, "loglevel=debug init=/bin/init")
    cmdline: ?[]const u8 = null,
    const Self = @This();
    pub fn init() Self {
        return .{
            // regions оставляем undefined, так как мы будем читать только до regions_count
            .regions_count = 0,
            .total_memory_bytes = 0,
            .framebuffer = null,
            .platform_config_ptr = null,
            .cmdline = null,
        };
    }
    pub fn add_region(self: *Self, start: u64, end: u64, kind: MemoryRegionKind) void {
        if (self.regions_count >= 64) {
            @panic("BootInfo пизда");
        }
        self.regions[self.regions_count] = MemoryRegion {
            .start = start,
            .end = end,
            .kind = kind
        };
        self.regions_count += 1;
        self.total_memory_bytes += (end - start);
    }
};



pub const FramebufferInfo = struct {
    addr: ?*anyopaque,
    width: u32,
    height: u32,
    bpp: u8,         // Bits per pixel (обычно 32)
    pitch: u32,       // Количество байт в одной строке (иногда != width * bpp)
    format: PixelFormat,
};


pub const PixelFormat = enum {
    Rgb,
    Bgr,
};

const PHYS_OFFSET: u64 = 0x0;
fn toVirt(phys: u64) u64 {
    return phys + PHYS_OFFSET;
}

pub const get_page = @import("alloc.zig").get_page;
pub const get_addr_from_page = @import("alloc.zig").get_addr_from_page;

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
    free_list_head: u64,

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

pub const AllocationSize = enum(u5) {
    _8B = 0,
    _16B = 1,
    _32B = 2,
    _64B = 3,
    _128B = 4,
    _256B = 5,
    _512B = 6,
    _1KB = 7,
    _2KB = 8,
    _4KB = 9,
    _8KB = 10,
    _16KB = 11,
    _32KB = 12,
    _64KB = 13,
    _128KB = 14,
    _256KB = 15,
    _512KB = 16,
    _1MB = 17,
    _2MB = 18,
    _4MB = 19,
    const Self = @This();
    pub fn from_size(size: usize, alignment: usize) Self {
        var required = if (size > alignment) size else alignment;
        if (required < 8) required = 8;
        const pow2 = math.ceilPowerOfTwo(usize, required) catch required;
        const bit = @as(u8, @intCast(@ctz(pow2)));
        const index = if (bit < 3) 0 else (bit - 3);
        return @enumFromInt(if (index > 19) 19 else index);
    }
    pub fn to_buddy_size(self: Self) u8 {
        assert(@intFromEnum(self) >= @intFromEnum(AllocationSize._4KB));
        return @intFromEnum(self) - 9;
    }
    pub fn from_buddy_order(order: u8) Self {
        return @enumFromInt(order + 9);
    }
    pub fn get_size(self: Self) usize {
        return switch (self) {
            Self._8B => 8,
            Self._16B => 16,
            Self._32B => 32,
            Self._64B => 64,
            Self._128B => 128,
            Self._256B => 256,
            Self._512B => 512,
            Self._1KB => 1024,
            Self._2KB => 2048,
            Self._4KB => 4096,
            Self._8KB => 8192,
            Self._16KB => 16384,
            Self._32KB => 32768,
            Self._64KB => 65536,
            Self._128KB => 131072,
            Self._256KB => 262144,
            Self._512KB => 524288,
            Self._1MB => 1048576,
            Self._2MB => 2097152,
            Self._4MB => 4194304,
        };
    }
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
        if (region.kind != MemoryRegionKind.Usable) {
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

            // 4. Работаем со страницей
            const page: *Page = get_page(&self.chunks, reg_ptr) orelse {
                return AllocatorError.UninitializedMetadata;
            };

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
fn get_buddy(chunks: *[MAX_CHUNKS]*Page, page: *Page) ?*Page {
    const current_pfn = get_addr_from_page(page, chunks) / 4096;
    const buddy_pfn = current_pfn ^ (@as(u32, 1) << @intCast(page.order));
    return get_page(chunks, buddy_pfn * 4096);
}


pub fn add_boot_regions(allocator: *BuddyAllocator, regions: *[64]?MemoryRegion) void {
    const metadata_size = @sizeOf(Page) * PAGES_PER_CHUNK;
    for (regions) |*region| {
        if (region.*) |*reg| {
            if (reg.start < BOOT_MAPPING_SIZE and reg.kind == MemoryRegionKind.Usable) {
                if (reg.end <= reg.start) { @panic("Region without any space! WTH?"); }
                if ((reg.end - reg.start) > (metadata_size * 2)) {
                    const start = (reg.start + 4095) & ~@as(u64, 4095);
                    const page1: [*]Page = @ptrFromInt(toVirt(start));
                    @memset(page1[0..PAGES_PER_CHUNK], std.mem.zeroes(Page));
                    const page2: [*]Page = @ptrFromInt(toVirt(start + metadata_size));
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
                        .kind = MemoryRegionKind.Usable
                    };
                    break;
                }
            }
        }
    }
    for (regions) |*region| {
        if (region.*) |*reg| {
            if (reg.start < BOOT_MAPPING_SIZE and reg.kind == MemoryRegionKind.Usable) {
                if (reg.end <= reg.start) { @panic("Region without any space! WTH?"); }
                if (allocator.add_region(MemoryRegion {
                    .start = reg.start,
                    .end = @min(reg.end, BOOT_MAPPING_SIZE),
                    .kind = MemoryRegionKind.Usable,
                })) |_| {
                    if (reg.end > BOOT_MAPPING_SIZE) {
                        region.* = MemoryRegion {
                            .start = BOOT_MAPPING_SIZE,
                            .end = reg.end,
                            .kind = MemoryRegionKind.Usable,
                        };
                    } else {
                        region.* = null;
                    }
                }
                else |_| {
                    // println("{}", &msg);
                }
            }
        }
    }
}



pub fn add_other_regions(allocator: *BuddyAllocator, regions: *[64]?MemoryRegion) void {
    defer allocator.unlock();
    var needed_chunks: [MAX_CHUNKS]bool = blk: {
        var chunks: [MAX_CHUNKS]bool = undefined;
        for (&chunks) |*c| {
            c.* = false;
        }
        break :blk chunks;
    };
    for (regions) |*region| {
        if (region.*) |*reg| {
            if (reg.kind == MemoryRegionKind.Usable) {
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
    for (needed_chunks, 0..) |*need_chunk, chunk_idx| {
        if (!need_chunk.*) { continue; }

        for (regions) |*region| {
            if (region.*) |*reg| {
                if (reg.end - reg.start >= metadata_size and reg.kind == MemoryRegionKind.Usable) {
                const virt_addr: [*]Page = @ptrFromInt(toVirt(reg.start));
                // Инициализируем
                @memset(virt_addr[0..PAGES_PER_CHUNK], 0);
                for (1..PAGES_PER_CHUNK) |offset | {
                    const page = &virt_addr[offset];
                    page.chunk = @intCast(chunk_idx);
                    page.set_magic();
                    page.flags = .{.no_owner = true, .is_free = false};
                }
                allocator.chunks[chunk_idx] = virt_addr;
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
            if (reg.kind == MemoryRegionKind.Usable) {
                allocator.add_region(reg.*) catch {
                    @panic("hell 627");
                    // std.debug.print("Failed to add region: {}\n", .{err});
                };
            }
        }
    }
}
