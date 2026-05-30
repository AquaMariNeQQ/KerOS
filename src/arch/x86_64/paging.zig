const PAGE_SIZE = 4096;
const AbstractPageFlags = @import("../../memory/vm.zig").AbstractPageFlags;
const toVirt = @import("../../utils.zig").toVirt;
const MapError = @import("../../memory/vm.zig").MapError;
const AddrSpace = @import("../../memory/vm.zig").AddrSpace;
const AllocationSize = @import("../../memory/memory.zig").AllocationSize;
const toPhys = @import("../../utils.zig").toPhys;
const PageTableEntry = struct {
    value: u64,

    pub fn present(self: *PageTableEntry) bool {
        return (self.value & 1) == 1;
    }

    pub fn setPresent(self: *PageTableEntry, value: bool) void {
        if (value) {
            self.value |= 1;
        } else {
            self.value &= ~@as(u64, 1);
        }
    }

    pub fn setAddr(self: *PageTableEntry, value: u64) void {
        self.value = (self.value & 0xfff0_0000_0000_0fff) | (value & 0x000f_ffff_ffff_f000);
    }

    pub fn setFlags(self: *PageTableEntry, flags: u64) void {
        self.value = (self.value & 0x000f_ffff_ffff_f000) | flags;
    }

    pub fn setHuge(self: *PageTableEntry, value: bool) void {
        if (value) {
            self.value |= 1 << 7;
        } else {
            self.value &= ~@as(u64, 1 << 7);
        }
    }
    pub fn huge(self: *PageTableEntry) bool {
        return (self.value & (1 << 7)) == 1;
    }

    pub fn addr(self: *PageTableEntry) *anyopaque {
        return @ptrFromInt(self.value & 0x000f_ffff_ffff_f000);
    }
};

fn translateFlags(flags: AbstractPageFlags, last: bool) u64 {
    var result: u64 = 1; // present always
    if (flags.writable) result |= 1 << 1;
    if (flags.user_accessable) result |= 1 << 2;
    if (last) {
        if (flags.write_through) result |= 1 << 3;
        if (flags.no_cache) result |= 1 << 4;
        if (flags.accessed) result |= 1 << 5;
        if (flags.dirty) result |= 1 << 6;
        if (flags.global) result |= 1 << 8;
        if (!flags.executable) result |= 1 << 63;
    }
    return result;
}

const PageTable = [512]PageTableEntry;
const SHIFTS = [4]u6 {12, 21, 30, 39};


fn supports1Gb() bool {
    var edx: u32 = undefined;
    asm volatile ("cpuid"
    : [_] "={edx}" (edx)
    : [_] "{eax}" (@as(u32, 0x80000001))
    : .{.eax = true, .ecx = true, .ebx = true}
    );
    return (edx & (1 << 26)) != 0;
}

fn check2MbDiv(addr: u64) bool {
    return addr % (PAGE_SIZE * 512) == 0;
}
fn check1GbDiv(addr: u64) bool {
    return addr % (PAGE_SIZE * (512 * 512)) == 0;
    // 512 * 512 = 262144 = (1024 * 1024 * 1024) / 4096 (which is page size).
}

const PageLevel = enum(u8) {
    PML4 = 3,
    PDPT = 2,
    PD = 1,
    PT = 0,
};

pub fn flushTlb(virt: *anyopaque) void {
    const addr = @intFromPtr(virt);
    asm volatile (
    \\invlpg %[page]
    :
    : [page] "m" (addr)
    : .{ .memory = true }
    );
}

pub fn flushTlbAll() void {
    asm volatile (
    \\mov %%cr3, %%cr3
    :
    :
    : .{.memory = true}
    );
}
pub fn mapRange(
    root: AddrSpace,
    virt: u64,
    phys: u64,
    size: usize,
    flags: AbstractPageFlags,
    allocator: anytype,
) MapError!void {
    comptime if (!@hasDecl(@TypeOf(allocator.*), "alloc") or @TypeOf(@TypeOf(allocator.*).alloc) != fn(@TypeOf(allocator), AllocationSize) ?*anyopaque) {
        @compileError("Allocator must have an 'alloc' method");
    };
    if (virt % PAGE_SIZE != 0 or size % PAGE_SIZE != 0
        or phys % PAGE_SIZE != 0) {
        return MapError.invalid_alignment;
    }
    const supports_1gb = supports1Gb();
    var left = size;
    var offset: u64 = 0;
    while (left > 0) {
        const current_virt = virt + offset;
            const use_1gb = supports_1gb
            and check1GbDiv(offset + phys)
            and check1GbDiv(offset + virt)
            and left >= (1024*1024*1024);
        const use_2mb = check2MbDiv(offset + phys)
            and check2MbDiv(offset + virt)
            and left >= (2*1024*1024);
        const current_map_size: u64 = if (use_1gb) PAGE_SIZE * 262144 else
            if (use_2mb) PAGE_SIZE * 512 else PAGE_SIZE;
        const max_depth = if (use_1gb) @intFromEnum(PageLevel.PDPT) else
            if (use_2mb) @intFromEnum(PageLevel.PD) else @intFromEnum(PageLevel.PT);

        var current_table: *PageTable = @ptrCast(@alignCast(root.root));
        var depth: i32 = 3;

        while (depth >= 0) : (depth -= 1) {
            const d: usize = @as(u6, @intCast(depth));
            const index = (current_virt >> SHIFTS[d]) & 0x1FF;

            const entry: *PageTableEntry = &current_table[index];
            if (depth == max_depth) {
                if (entry.present()) {
                    return MapError.overlap;
                }
                entry.setAddr(phys + offset);
                entry.setFlags(translateFlags(flags, true));
                entry.setHuge(use_1gb or use_2mb);
                flushTlb(@ptrFromInt(current_virt));
                break;
            } else {
                if (!entry.present()) {
                    const new_page = allocator.alloc(._4KB) orelse return MapError.out_of_memory;
                    entry.setAddr(@intFromPtr(new_page));
                    entry.setPresent(true);
                    const new_table: *PageTable = @ptrCast(@alignCast(toVirt(new_page)));
                    @memset(new_table, .{ .value = 0 });
                }
                entry.setFlags(translateFlags(flags, false));
                current_table = @ptrCast(@alignCast(toVirt(entry.addr())));
            }
        }
        offset += current_map_size;
        left -= current_map_size;
    }
}

pub fn remapRange(
    root: *PageTable,
    virt: u64,
    size: usize,
    flags: AbstractPageFlags,
) MapError!void {
    if (virt % PAGE_SIZE != 0 or size % PAGE_SIZE != 0) {
        return MapError.invalid_alignment;
    }
    const supports_1gb = supports1Gb();
    var left = size;
    var offset: u64 = 0;
    while (left > 0) {
        const current_virt = virt + offset;
        const use_1gb = supports_1gb
            and check1GbDiv(offset + virt)
            and left >= (1024*1024*1024);
        const use_2mb = check2MbDiv(offset + virt)
            and left >= (2*1024*1024);
        const current_map_size: u64 = if (use_1gb) PAGE_SIZE * 262144 else
            if (use_2mb) PAGE_SIZE * 512 else PAGE_SIZE;
        const max_depth = if (use_1gb) @intFromEnum(PageLevel.PDPT) else
            if (use_2mb) @intFromEnum(PageLevel.PD) else @intFromEnum(PageLevel.PT);
        var current_table: *PageTable = toVirt(root);
        var depth: i32 = 3;
        while (depth >= 0) : (depth -= 1) {
            const d: usize = @as(u6, @intCast(depth));
            const index = (current_virt >> SHIFTS[d]) & 0x1FF;
            const entry: *PageTableEntry = &current_table[index];
            if (!entry.present()) {
                return MapError.page_not_present;
            }
            if (depth == max_depth) {
                entry.setFlags(translateFlags(flags, true));
                entry.setHuge(entry.huge());
                flushTlb(current_virt);
                break;
            } else {
                if (entry.huge()) {
                    return MapError.unexpected_huge_page;
                }
                entry.setFlags(translateFlags(flags, false));
                current_table = toVirt(entry.addr());
            }
        }
        offset += current_map_size;
        left -= current_map_size;
    }
}

pub fn newAddrSpace(allocator: anytype) ?AddrSpace {
    comptime if (!@hasDecl(@TypeOf(allocator.*), "alloc") or @TypeOf(@TypeOf(allocator.*).alloc) != fn(@TypeOf(allocator), AllocationSize) ?*anyopaque) {
        @compileError("Allocator must have an 'alloc' method");
    };
    const phys = allocator.alloc(._4KB) orelse return null;
    const virt = toVirt(phys);
    const vtable: *[512]PageTableEntry = @ptrCast(@alignCast(virt));
    @memset(vtable, .{.value = 0});
    return AddrSpace {.root = virt};
}

pub fn install(space: *AddrSpace) void {

    asm volatile (
        \\ mov %[pml4], %%cr3
        :
        : [pml4] "r" (toPhys(space.root))
        : .{.memory = true}
    );
}