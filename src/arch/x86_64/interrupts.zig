const println = @import("../../utils.zig").println;
pub const IDTEntry = packed struct(u128) {
    offset_low: u16,
    selector: u16,
    ist: u3,
    reserved: u5 = 0,
    type: u4,
    zero: u1,
    dpl: u2,
    present: u1,
    offset_mid: u16,
    offset_high: u32,
    reserved1: u32 = 0,
};

var idt = make: {
    var entries: [256]IDTEntry = undefined;
    for (&entries) |*entry| {
        entry.* = .{
            .offset_low = 0,
            .selector = 0,
            .ist = 0,
            .reserved = 0,
            .type = 0,
            .zero = 0,
            .dpl = 0,
            .present = 0,
            .offset_mid = 0,
            .offset_high = 0
        };
    }
    break :make entries;
};

pub fn setup() void {
    idtr.base = @intFromPtr(&idt);
    for (0..256) |i| {
        idt[i] = .{
            .offset_low = @truncate(int_stub_array[i]),
            .selector = 0x08, // kernel code selector
            .ist = if (i < 33) 1 else 0, // todo
            .type = 0xE,
            .zero = 0,
            .dpl = 0,
            .present = 1,
            .offset_mid = @truncate(int_stub_array[i] >> 16),
            .offset_high = @truncate(int_stub_array[i] >> 32),
        };
    }
}

comptime {
    if (@sizeOf(IDTEntry) != 16) {
        @compileError("fuck 5");
    }
    if (@sizeOf(IDTR) != 10) {
        @compileError("fuck 6");
    }
    if (@sizeOf([256]IDTEntry) - 1 != 4095) {
        @compileError("fuck 7");
    }
}

pub fn loadInterruptTable() void {
    asm volatile (
        \\lidt (%[idtr])
        :
        : [idtr] "r" (&idtr)
        : .{.memory = true}
    );
}

const IDTR = extern struct {
    limit: u16 align(1),
    base: u64 align(1),
};

var idtr = IDTR {
    .limit = @sizeOf([256]IDTEntry) - 1,
    .base = undefined
};

pub fn disableInterrupts() void {
    asm volatile (
        \\cli
        ::: .{.memory = true}
    );
}

pub fn enableInterrupts() void {
    asm volatile (
        \\sti
        ::: .{.memory = true}
    );
}

extern const int_stub_array: [256]usize;