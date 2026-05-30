pub const SchedulerQueue = struct {};
const ALLOCATOR = @import("../memory/memory.zig").ALLOCATOR;
const toVirt = @import("../utils.zig").toVirt;
const PCD = @import("../arch.zig").PCDSource;
const CpuLocalBuddyAllocator = @import("../memory/alloc/buddy_local.zig").CpuLocalBuddyAllocator;
const SlubAllocator = @import("../memory/alloc/slub.zig").SlubAllocator;
pub const PerCpuData = struct {
    self_pointer: *const PerCpuData,
    cpu_id: u8,
    current_stack_ptr: ?*anyopaque,
    preemption_count: u16,
    run_queue: ?SchedulerQueue,
    local_buddy: CpuLocalBuddyAllocator,
    local_slub: SlubAllocator,
    arch_specific_data_ptr: ?*anyopaque,

    // -----------------------------

    fn new(cpu_id: u8) *PerCpuData {
        const phys: *anyopaque = a: {
            const alloc = ALLOCATOR.lock();
            defer ALLOCATOR.unlock();
            break :a alloc.alloc(._4KB) orelse @panic("OOM");
        };
        const virt: *PerCpuData = @ptrCast(@alignCast(toVirt(phys)));
        const cpu_local_buddy = CpuLocalBuddyAllocator.new(cpu_id);
        const cpu_local_slub = SlubAllocator.new(cpu_id);
        const data = PerCpuData {
            .self_pointer = virt,
            .cpu_id = cpu_id,
            .current_stack_ptr = null,
            .preemption_count = 0,
            .run_queue = null,
            .local_buddy = cpu_local_buddy,
            .local_slub = cpu_local_slub,
            .arch_specific_data_ptr = null,
        };
        virt.* = data;
        CPU_DATA[cpu_id] = virt;
        return virt;
    }
};
pub var CPU_DATA = blk: {
    var lst: [256]?*PerCpuData = undefined;
    for (&lst) |*ls| {
        ls.* = null;
    }
    break :blk lst;
};
pub fn createPerCpu(cpu_id: u8) void {
    const data = PerCpuData.new(cpu_id);
    PCD.installPerCpu(data);
}