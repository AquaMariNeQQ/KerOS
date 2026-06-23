const std = @import("std");
pub const GDT = extern struct {
    null_entry: GDTEntry align(1) = .{},
    kernel_code: GDTEntry align(1),
    kernel_data: GDTEntry align(1),
    usermode_code: GDTEntry align(1),
    usermode_data: GDTEntry align(1),
    tss: GDTTSSEntry align(1),

    pub fn new(tss_addr: u64) GDT {
        return .{
            .kernel_code = .{
                .access = 0x9a, // present, r0, executable, readable,
                .granularity = 0xaf, // 64 bit
                .limit_low = 0xFFFF,
            },
            .kernel_data = .{
                .access = 0x92, // present, r0, writable, readable
                .granularity = 0x00
            },
            .usermode_code = .{
                .access = 0xfa,
                .granularity = 0xcf,
            },
            .usermode_data = .{
                .access = 0xf2,
                .granularity = 0x00,
            },
            .tss = .{
                .limit_low = 104,
                .base_low = @truncate(tss_addr & 0xFFFF),
                .base_mid = @truncate((tss_addr >> 16) & 0xFF),
                .access = 0x89, // present, r0, tss
                .granularity = 0x00,
                .base_high = @truncate((tss_addr >> 24) & 0xFF),
                .base_upper = @truncate((tss_addr >> 32) & 0xFFFFFFFF)
            }
        };
    }
    pub fn load(ptr: *GDTR) void {
        asm volatile (
            \\lgdt (%[addr])
            :
            : [addr] "r" (ptr)
        );
    }
};

pub const GDTR = extern struct {
    size: u16 align(1),
    addr: u64 align(1)
};

const GDTEntry = packed struct (u64) {
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_mid: u8 = 0,
    access: u8 = 0,
    granularity: u8 = 0,
    base_high: u8 = 0,
};

const GDTTSSEntry = packed struct (u128) {
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_mid: u8 = 0,
    access: u8 = 0,
    granularity: u8 = 0,
    base_high: u8 = 0,
    base_upper: u32 = 0,
    reserved: u32 = 0,
};