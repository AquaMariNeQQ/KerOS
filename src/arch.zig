const builtin = @import("builtin");
const BootInfo = @import("bootsource.zig").BootInfo;
const PerCpuData = @import("smp/percpu.zig").PerCpuData;
const AbstractPageFlags = @import("memory/vm.zig").AbstractPageFlags;
const MapError = @import("memory/vm.zig").MapError;
const AddrSpace = @import("memory/vm.zig").AddrSpace;

pub const arch = if (builtin.target.cpu.arch == .x86_64) @import("arch/x86_64/impl.zig")
else @compileError("Архитектура ещё не поддерживается!");

pub const CBSource =
    if (@hasDecl(arch.bootsource, "parse") and @TypeOf(arch.bootsource.parse) == fn (*anyopaque) BootInfo) arch.bootsource
    else @compileError("Bootsource must implement the 'parse' function");
pub const write_bytes =
    if (@hasDecl(arch.utils, "print") and @TypeOf(arch.utils.print) == fn ([]const u8) void) arch.utils.print
    else @compileError("Arch Implementation must implement the 'print' function");
pub const PCDSource =
    if (@hasDecl(arch.PerCpuUtils, "getPerCpu") and @TypeOf(arch.PerCpuUtils.getPerCpu) == fn() *PerCpuData
        and @hasDecl(arch.PerCpuUtils, "installPerCpu") and @TypeOf(arch.PerCpuUtils.installPerCpu) == fn(*PerCpuData) void) arch.PerCpuUtils
    else @compileError("PerCpuUtils in arch must implement 'installPerCpu' and 'getPerCpu'");
pub const Paging =
    if (
        (@hasDecl(arch.Paging, "mapRange") and @TypeOf(arch.Paging.mapRange) == fn(AddrSpace, u64, u64, usize, AbstractPageFlags, anytype) MapError!void)
        and (@hasDecl(arch.Paging, "flushTlb") and @TypeOf(arch.Paging.flushTlb) == fn(*anyopaque) void )
        and (@hasDecl(arch.Paging, "flushTlbAll") and @TypeOf(arch.Paging.flushTlbAll) == fn() void)
        and (@hasDecl(arch.Paging, "newAddrSpace") and @TypeOf(arch.Paging.newAddrSpace) == fn(anytype) ?AddrSpace)
    ) arch.Paging
    else @compileError("Paging in arch must implement 'mapRange', 'remapRange', 'unmapRange', 'flushTlb' and 'flushTlbAll'");
pub const InterruptHandlers =
    if (
        (@hasDecl(arch.InterruptSettings, "loadInterruptTable") and @TypeOf(arch.InterruptSettings.loadInterruptTable) == fn () void )
        and (@hasDecl(arch.InterruptSettings, "setup") and @TypeOf(arch.InterruptSettings.setup) == fn() void)
    ) arch.InterruptSettings
    else @compileError("InterruptHandlers in arch must implement 'loadInterruptTable' and 'setup'");

pub const ArchSpecific =
    if (
        @hasDecl(arch.PerCpuUtils, "cpuSetup") and @TypeOf(arch.PerCpuUtils.cpuSetup) == fn() void
    ) arch.Specific
    else @compileError("Specific in arch must implement 'setup'");