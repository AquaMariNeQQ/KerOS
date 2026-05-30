const toVirt = @import("utils.zig").toVirt;
const println = @import("utils.zig").println;
const Paging = @import("arch.zig").Paging;
const ALLOCATOR = @import("memory/memory.zig").ALLOCATOR;
const add_boot_regions = @import("memory/alloc/buddy.zig").add_boot_regions;
const AddrSpace = @import("memory/vm.zig").AddrSpace;
const add_other_regions = @import("memory/alloc/buddy.zig").add_other_regions;
const AbstractPageFlags = @import("memory/vm.zig").AbstractPageFlags;
const MemoryRegionKind = @import("memory/memory.zig").MemoryRegionKind;
const InterruptSetup = @import("arch.zig").InterruptHandlers;
const InterruptHandler = @import("interrupts/dispatcher.zig");
const CBS = @import("arch.zig").CBSource;
const std = @import("std");
const PCD = @import("arch.zig").PCDSource;
const PHYS_OFFSET = @import("utils.zig").PHYS_OFFSET;
const createPerCpu = @import("smp/percpu.zig").createPerCpu;


comptime {
    @export(&InterruptHandler.int_dispatch, .{ .name = "int_dispatch", .linkage = .strong });
}

pub export fn _start_kernel(boot_info_ptr: *anyopaque) callconv(.c) noreturn {
    InterruptSetup.disableInterrupts();
    ALLOCATOR.init();
    const boot_info_virt = toVirt(boot_info_ptr);
    const info = CBS.parse(boot_info_virt);
    var regions = info.regions;
    { // add boot regions
        const alloc = ALLOCATOR.lock();

        add_boot_regions(alloc, &regions);
        ALLOCATOR.unlock();
    } // end

    createPerCpu(0);
    const newspace = a: {
        const alloc = ALLOCATOR.lock();
        defer ALLOCATOR.unlock();
        break :a Paging.newAddrSpace(alloc);
    } orelse @panic("OOM, we're fucked already");



    const flags = AbstractPageFlags {.writable = true, .executable = true};
    for (info.regions) |region| {
        if (region) |reg| {
            if (reg.kind != MemoryRegionKind.kernel and reg.kind != MemoryRegionKind.usable) { continue; }
            const start = (reg.start + 0xFFF) & ~@as(u64, 0xFFF);
            const end = reg.end & ~@as(u64, 0xFFF);
            const virt_start = toVirt(@ptrFromInt(start));
            const alloc = ALLOCATOR.lock();
            defer ALLOCATOR.unlock();
            if (Paging.mapRange(newspace, @intFromPtr(virt_start), start, (end - start), flags, alloc)) |_| {} else |_| {
                @panic("we're fucked");
            }
        }
    }
    Paging.install(@constCast(&newspace));
    {
        const alloc = ALLOCATOR.lock();
        add_other_regions(alloc, &regions);
        ALLOCATOR.unlock();
    }
    PCD.cpuSetup();

    while (true) {
        asm volatile ("hlt");
    }
}
pub const panic = @import("panic.zig").panic;

