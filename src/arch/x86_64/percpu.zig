const PerCpuData = @import("../../smp/percpu.zig").PerCpuData;
const GDT = @import("gdt.zig").GDT;
const GDTR = @import("gdt.zig").GDTR;
const Interrupts = @import("impl.zig").InterruptSettings;
const TSS = @import("tss.zig").TSS;
const toVirt = @import("../../utils.zig").toVirt;
const toPhys = @import("../../utils.zig").toPhys;

pub fn installPerCpu(addr: *PerCpuData) void {
    const addr_u64 = @intFromPtr(addr);
    const low: u32 = @truncate(addr_u64);
    const high: u32 = @truncate(addr_u64 >> 32);
    asm volatile (
        \\wrmsr
    :
    :
      [msr] "{ecx}" (0xC0000101),
      [eax] "{eax}" (low),
      [edx] "{edx}" (high),

    : .{.memory = true}
    );
}

pub fn getPerCpu() *PerCpuData {
    var ptr: *PerCpuData = undefined;
    asm volatile(
        \\mov %%gs:0, %[out]
    : [out] "=r" (ptr),
    :

    );
    return ptr;
}
const println = @import("../../utils.zig").println;

pub fn cpuSetup() void {
    const allocator = &getPerCpu().local_slub;
    const allocated = toVirt(allocator.alloc(._256B) orelse @panic("OOM, we're fucked already, there's no point to continue"));
    const data: *CPUSetupData = @ptrCast(@alignCast(allocated));
    const tss = TSS.new();
    data.tss = tss;
    data.gdt = GDT.new(@intFromPtr(&data.tss));
    data.gdtr = .{
        .size = @sizeOf(GDT) - 1,
        .addr = @intFromPtr(&data.gdt)
    };
    GDT.load(&data.gdtr);
    TSS.ltr();
    Interrupts.setup();
    Interrupts.loadInterruptTable();
    Interrupts.enableInterrupts();
}

const CPUSetupData = struct {
    gdt: GDT,
    gdtr: GDTR,
    tss: TSS
};