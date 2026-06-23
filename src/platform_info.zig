

pub const PlatformInfo = struct {
    // interrupt_controller: [256]?InterruptController,
    interrupt_controller: InterruptController,
    // local_timer: [256]?Timer,
    local_timer: Timer,
    high_precision_timer: HPTimer,
    power: PowerControl,
};

pub const InterruptController = struct {
    ptr: *anyopaque,
    eoi: *const fn(ptr: *anyopaque) void,
    mapIrq: *const fn(ptr: *anyopaque, irq: u8, vector: u8, cpuid: u16) void,
    enableIrq: *const fn(ptr: *anyopaque, irq: u8) void,
    disableIrq: *const fn(ptr: *anyopaque, irq: u8) void,
    isHardwareInterrupt: *const fn(ptr: *anyopaque, vector: u8) bool,
};

pub const PowerControl = struct {
    ptr: *anyopaque,
    shutdown: *const fn(ptr: *anyopaque) noreturn,
    reboot: *const fn(ptr: *anyopaque) noreturn,
};

// HPTimer - глобальный источник времени
pub const HPTimer = struct {
    ptr: *anyopaque,
    getCurrentNs: *const fn(ptr: *anyopaque) u64,
    getFrequencyHz: *const fn(ptr: *anyopaque) u64,
};

// Timer - per-CPU таймер планировщика
pub const Timer = struct {
    ptr: *anyopaque,
    setOneshot: *const fn(ptr: *anyopaque, ns: u64) void,
    setRepeating: *const fn(ptr: *anyopaque, ns: u64) void,
    stop: *const fn(ptr: *anyopaque) void,
};