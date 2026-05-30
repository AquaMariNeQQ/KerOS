const CpuDataProvider = @import("../../arch.zig").PCDSource;
const GDT = @import("gdt.zig").GDT;
const toVirt = @import("../../utils.zig").toVirt;
const println = @import("../../utils.zig").println;

pub const TSS = extern struct {
    reserved0: u32 align(2) = 0,
    rsp0: u64 align(2) = 0,
    rsp1: u64 align(2) = 0,
    rsp2: u64 align(2) = 0,
    reserved1: u64 align(2) = 0,
    ist1: u64 align(2) = 0,
    ist2: u64 align(2) = 0,
    ist3: u64 align(2) = 0,
    ist4: u64 align(2) = 0,
    ist5: u64 align(2) = 0,
    ist6: u64 align(2) = 0,
    ist7: u64 align(2) = 0,
    reserved2: u64 align(2) = 0,
    reserved3: u16 align(2) = 0,
    io_map_base: u16 align(2) = 0,

    pub fn new() TSS {
        const percpu = CpuDataProvider.getPerCpu();
        const rsp0 = toVirt(percpu.local_buddy.alloc(._8KB) orelse @panic("OOM"));
        const ist1 = toVirt(percpu.local_buddy.alloc(._8KB) orelse @panic("OOM"));

        const tss: TSS align (1)  = TSS {
            .rsp0 = @intFromPtr(rsp0) + 8192,
            .ist1 = @intFromPtr(ist1) + 8192,
            .io_map_base = 0xFFFF,
        };

        return tss;
    }
    pub fn ltr() void {
        asm volatile (
            \\ltr %[addr]
            :
        : [addr] "r" (@as(u16, 40)) // 40 - 5 * 8 дескрипторов в GDT
        );
    }
};