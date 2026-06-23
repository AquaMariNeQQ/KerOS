const Spinlock = @import("../datastructs/spinlock.zig").Spinlock;
const BuddyAllocator = @import("alloc/buddy.zig").BuddyAllocator;

pub const MemoryRegionKind = enum {
    /// Свободная память, которую Buddy может забрать себе
    usable,
    /// Зарезервировано железом (ACPI, BIOS, IO) — НЕ ТРОГАТЬ
    reserved,
    /// Здесь лежит само ядро (уже занято)
    kernel,
    /// Здесь лежат данные загрузчика (Multiboot/DTB)
    /// После инициализации это можно будет освободить
    bootloader,
    /// Дефектная память
    bad,

};


pub const MemoryRegion = struct {
    start: u64,
    end: u64,
    kind: MemoryRegionKind,
    pub fn size(self: @This()) usize {
        return @as(usize, (self.end - self.start));
    }
};

// Скрытая переменная, которая будет лежать в секции .data
var internal_allocator: Spinlock(BuddyAllocator) = .{
    .lock_value = false,
    .data = undefined,
};

// Публичная константа, к которой ты обращаешься
pub const ALLOCATOR = &internal_allocator;
const math = @import("std").math;
const assert = @import("std").debug.assert;


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