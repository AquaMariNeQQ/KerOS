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
const InterruptHandler = @import("interrupts/dispatcher.zig").InterruptHandler;
const IntDPCHR = @import("interrupts/dispatcher.zig");
const CBS = @import("arch.zig").CBSource;
const std = @import("std");
const PCD = @import("arch.zig").PCDSource;
const PHYS_OFFSET = @import("utils.zig").PHYS_OFFSET;
const createPerCpu = @import("smp/percpu.zig").createPerCpu;
const CPIS = @import("arch.zig").CurrentPlInfoSource;
const vm = @import("memory/vm.zig");
const subscribe = @import("interrupts/dispatcher.zig").subscribe;
const pf_handler = @import("arch.zig").pf_handler;

comptime {
    @export(&IntDPCHR.int_dispatch, .{ .name = "int_dispatch", .linkage = .strong });
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
    const newspace = make: {
        const alloc = ALLOCATOR.lock();
        defer ALLOCATOR.unlock();
        break :make Paging.newAddrSpace(alloc);
    } orelse @panic("OOM, we're screwed already");
    const flags = AbstractPageFlags {.writable = true, .executable = true};
    for (info.regions) |region| {
        if (region) |reg| {
            if (reg.kind != MemoryRegionKind.kernel and reg.kind != MemoryRegionKind.usable and reg.kind != MemoryRegionKind.bootloader) { continue; }
            const start = (reg.start + 0xFFF) & ~@as(u64, 0xFFF);
            const end = reg.end & ~@as(u64, 0xFFF);
            const virt_start = toVirt(@ptrFromInt(start));
            const alloc = ALLOCATOR.lock();
            defer ALLOCATOR.unlock();
            Paging.mapRange(newspace, @intFromPtr(virt_start), start, (end - start), flags, alloc)
                catch @panic("we're screwed");
        }
    }
    Paging.install(@constCast(&newspace));
    {
        const alloc = ALLOCATOR.lock();
        add_other_regions(alloc, &regions);
        ALLOCATOR.unlock();
    }
    vm.MMIOVMalloc = .{.kernel_space = .{.data = newspace}};
    PCD.cpuSetup();
    const pl_info = CPIS.parse(info.platform_config_ptr orelse @panic("we're screwed, there's no point to continue"));
    PCD.getPerCpu().local_ic = pl_info.interrupt_controller;
    const ic = PCD.getPerCpu().local_ic;
    ic.mapIrq(ic.ptr, 1, 33, 0); // IRQ1 -> вектор 33, CPU 0
    ic.enableIrq(ic.ptr, 1);
    var pf_hdlr = InterruptHandler {
        .handler = pf_handler,
        .list_node = .{.next = null, .prev = null}
    };
    subscribe(14, &pf_hdlr);
    while (true) {
        asm volatile ("hlt");
    }
}
pub const panic = @import("panic.zig").panic;

