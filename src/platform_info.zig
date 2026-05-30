comptime {
    if (!@hasDecl(InterruptController, "eoi") or @TypeOf(InterruptController.eoi) != fn(vector: u8) void) {
        @compileError("InterruptController must implement 'fn eoi(u8)void'");
    }
    if (!@hasDecl(InterruptController, "mapIrq") or @TypeOf(InterruptController.mapIrq) != fn(irq: u8, vector: u8, flags: u8) void) {
        @compileError("InterruptController must implement 'fn mapIrq(u8, u8, u8)void'");
    }
    if (!@hasDecl(InterruptController, "enableIrq") or @TypeOf(InterruptController.enableIrq) != fn(irq: u8) void) {
        @compileError("InterruptController must implement 'fn enableIrq(u8)void'");
    }
    if (!@hasDecl(InterruptController, "disableIrq") or @TypeOf(InterruptController.disableIrq) != fn(irq: u8) void) {
        @compileError("InterruptController must implement 'fn disableIrq(u8)void'");
    }
    if (!@hasDecl(Timer, "getCurrentNs") or @TypeOf(Timer.getCurrentNs) != fn() u64) {
        @compileError("Timer must implement 'fn getCurrentNs()u64'");
    }
    if (!@hasDecl(Timer, "setOneshot") or @TypeOf(Timer.setOneshot) != fn(ns: u64) void) {
        @compileError("Timer must implement 'fn setOneshot(u64)void'");
    }
    if (!@hasDecl(Timer, "setRepeating") or @TypeOf(Timer.setRepeating) != fn(ns: u64) void) {
        @compileError("Timer must implement 'fn setRepeating(u64)void'");
    }
    if (!@hasDecl(Timer, "calibrate") or @TypeOf(Timer.calibrate) != fn() void) {
        @compileError("Timer must implement 'fn calibrate()void'");
    }
    if (!@hasDecl(PowerControl, "calibrate") or @TypeOf(PowerControl.shutdown) != fn() noreturn) {
        @compileError("PowerControl must implement 'fn shutdown()noreturn'");
    }
    if (!@hasDecl(PowerControl, "reboot") or @TypeOf(PowerControl.reboot) != fn () noreturn) {
        @compileError("PowerControl must implement 'fn reboot()noreturn'");
    }

}

pub const PlatformInfo = struct {
    interrupt_controller: InterruptController,
    timers: Timer,
    power: PowerControl,
};