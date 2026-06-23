const PlatformInfo = @import("../../platform_info.zig").PlatformInfo;
const toVirt = @import("../../utils.zig").toVirt;
const std = @import("std");
const HPTimer = @import("../../platform_info.zig").HPTimer;
const vm = @import("../../memory/vm.zig");
const addBytes = @import("../../utils.zig").addBytes;
const Port = @import("archutils.zig").Port;

const AcpiHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_rev: u32,
    creator_id: u32,
    creator_rev: u32,
};

const Fadt = extern struct {
    header: AcpiHeader,
    firmware_ctrl: u32,
    dsdt: u32,
    reserved: u8,
    preferred_pm_profile: u8,
    sci_interrupt: u16,
    smi_cmd: u32,
    acpi_enable: u8,
    acpi_disable: u8,
    s4bios_req: u8,
    pstate_cnt: u8,
    pm1a_evt_blk: u32,
    pm1b_evt_blk: u32,
    pm1a_cnt_blk: u32,  //
    pm1b_cnt_blk: u32,
};


const Madt = extern struct {
    header: AcpiHeader,
    lapic_addr: u32,
    flags: u32,

};

const MadtEntryHeader = extern struct {
    entry_type: u8,
    len: u8
};

const MadtIoApic = extern struct {
    heaeder: MadtEntryHeader,
    id: u8,
    reserved: u8,
    addr: u32,
    gsi_base: u32,
};

const MadtIrqOverride = extern struct {
    header: MadtEntryHeader,
    bus: u8,
    irq: u8,
    gsi: u32,
    flags: u16,
};

const HpetTable = extern struct {
    header: AcpiHeader align(1),
    event_timer_block_id: u32 align(1),
    base_address: extern struct {
        address_space_id: u8 align(1),
        register_bit_width: u8 align(1),
        register_bit_offset: u8 align(1),
        access_size: u8 align(1),
        address: u64 align(1),
    },
    hpet_number: u8 align(1),
    minimum_tick: u16 align(1),
    page_protection: u8 align(1),
};

pub fn parse(addr: *anyopaque) PlatformInfo {
    const xsdt: *AcpiHeader = @ptrCast(@alignCast(addr));
    const entries = (xsdt.length - @sizeOf(AcpiHeader)) / 8;
    const ptrs: [*]align(1)u64 = @ptrFromInt(@intFromPtr(xsdt) + @sizeOf(AcpiHeader));
    for (0..entries) |i| {
        const table: *AcpiHeader = @ptrCast(@alignCast(toVirt(@ptrFromInt(ptrs[i]))));
        if (std.mem.eql(u8, &table.signature, "APIC")) parseMadt(table);
        if (std.mem.eql(u8, &table.signature, "FACP")) parseFadt(table);
        if (std.mem.eql(u8, &table.signature, "HPET")) parseHpet(table);
    }

    lapic_instance.calibrate(&hpet_instance);
    // for (&info.local_timer) |*timer| {
    // if (timer.*) |tmr|{
// LAPIC.calibrate(@ptrCast(@alignCast(tmr.ptr)), &hpet_instance);
// }
// }
    return buildPlatformInfo();
}

pub fn buildPlatformInfo() PlatformInfo {
    return .{
        .interrupt_controller = .{
            .ptr = &ioapic_instance,
            .eoi = LAPIC.eoiWrapper,
            .mapIrq = IOAPIC.mapIrqWrapper,
            .enableIrq = IOAPIC.enableIrqWrapper,
            .disableIrq = IOAPIC.disableIrqWrapper,
            .isHardwareInterrupt = LAPIC.isHardwareInterruptWrapper,
        },
        .local_timer = .{
            .ptr = &lapic_instance,
            .setOneshot = LAPIC.setOneshotWrapper,
            .setRepeating = LAPIC.setRepeatingWrapper,
            .stop = LAPIC.stopWrapper,
        },
        .high_precision_timer = hpet_instance.hptimer(),
        .power = .{
            .ptr = @ptrFromInt(0xdeadbeef),
            .shutdown = shutdown,
            .reboot = undefined
        }, // todo
    };
}

var ioapic_instance: IOAPIC = undefined;
// var lapics: [256]?LAPIC = @splat(null);
var lapic_instance: LAPIC = undefined;
fn parseMadt(table: *AcpiHeader) void {
    const madt: *Madt = @ptrCast(table);
    // for (&lapics) |*lapic| {
        // if (lapic == null) {
            // lapic.* = LAPIC.init(madt.lapic_addr);
            lapic_instance = LAPIC.init(madt.lapic_addr);
        // }
    // }
    var offset: usize = @sizeOf(Madt);
    while (offset < madt.header.length) {
        const entry: *MadtEntryHeader = @ptrFromInt(@intFromPtr(madt) + offset);
        switch (entry.entry_type) {
            0 => {
                // lapic (cpu) found
            },
            1 => {
                const ioapic: *align(1) MadtIoApic = @ptrCast(entry);
                ioapic_instance = IOAPIC.init(ioapic.addr, ioapic.gsi_base);
                IOAPIC.disablePIC();
            },
            else => {} // maybe in the future
        }
        offset += entry.len;
    }
}
var pm1a_cnt_port: u16 = 0;
fn parseFadt(table: *AcpiHeader) void {
    const fadt: *Fadt = @ptrCast(@alignCast(table));
    pm1a_cnt_port = @truncate(fadt.pm1a_cnt_blk);
}
pub fn shutdown(_: *anyopaque) noreturn {
    var port = Port{.port = 0xf4};
    port.outw(0); // exit code 1
    while (true) asm volatile ("hlt");
}
fn parseHpet(table: *AcpiHeader) void {
    const hpetable: *HpetTable = @ptrCast(@alignCast(table));
    hpet_instance = Hpet.init(hpetable.base_address.address);
}

var hpet_instance: Hpet = undefined;

pub const Hpet = struct {
    base: *anyopaque,
    period_fs: u64,

    pub fn init(phys_addr: u64) Hpet {
        const base = vm.MMIOVMalloc.iomap(phys_addr, 0x1000);

        const gcap: *volatile u64 = @ptrCast(@alignCast(base));
        const period_fs = gcap.* >> 32;
        const conf: *volatile u64 = @ptrCast(@alignCast(addBytes(base, 0x10)));
        conf.* |= 1;
        return .{.base = base, .period_fs = period_fs};
    }

    pub fn getCurrentNs(self: *Hpet) u64 {
        const cnt: *volatile u64 = @ptrCast(@alignCast(addBytes(self.base, 0xf0)));
        return cnt.* * self.period_fs / 1_000_000;
    }

    pub fn getFrequencyHz(self: *Hpet) u64 {
        return 1_000_000_000_000_000 / self.period_fs;
    }

    pub fn hptimer(self: *Hpet) HPTimer {
        return .{
            .ptr = self,
            .getCurrentNs = wrapper1,
            .getFrequencyHz = wrapper2
        };
    }
    fn wrapper1(ptr: *anyopaque) u64 {
        const self: *Hpet = @ptrCast(@alignCast(ptr));
        return self.getCurrentNs();
    }
    fn wrapper2(ptr: *anyopaque) u64 {
        const self: *Hpet = @ptrCast(@alignCast(ptr));
        return self.getFrequencyHz();
    }
};

pub const IOAPIC = struct {
    base: *anyopaque,
    gsi_base: u32,
    fn init(phys: u64, gsi_base: u32) @This() {
        const base = vm.MMIOVMalloc.iomap(phys, 0x1000);
        var self: @This() = .{.base = base, .gsi_base = gsi_base};
        const ver = self.readReg(0x01);
        const max_irq: u8 = @truncate((ver >> 16) & 0xFF); // интересная формула
        for (0..max_irq + 1) |i| {
            const I: u8 = @intCast(i);
            self.writeReg(0x10 + I * 2, 1 << 16); // masked
            self.writeReg(0x10 + I * 2 + 1, 0);
        }
        return self;
    }
    fn disablePIC() void {
        var port = Port {.port = 0x21};
        port.outb(0xff);
        var port2 = Port {.port = 0xa1};
        port2.outb(0xff);
    }
    fn writeReg(self: *@This(), reg: u8, val: u32) void {
        const sel: *volatile u32 = @ptrCast(@alignCast(self.base));
        const win: *volatile u32 = @ptrCast(@alignCast(addBytes(self.base, 0x10)));
        sel.* = reg;
        win.* = val;
    }
    fn readReg(self: *@This(), reg: u8) u32 {
        const sel: *volatile u32 = @ptrCast(@alignCast(self.base));
        const win: *volatile u32 = @ptrCast(@alignCast(addBytes(self.base, 0x10)));
        sel.* = reg;
        return win.*;
    }
    fn mapIrq(self: *@This(), irq: u8, vector: u8, cpuid: u16) void {
        const lo_reg: u8 = 0x10 + irq * 2; // интересная формула.
        const hi_reg: u8 = lo_reg + 1;
        self.writeReg(hi_reg, @as(u32, cpuid) << 24); // интересная формула
        self.writeReg(lo_reg, vector);
    }
    fn enableIrq(self: *@This(), irq: u8) void {
        const lo_reg: u8 = 0x10 + irq * 2; // интересная формула.
        const val = self.readReg(lo_reg);
        self.writeReg(lo_reg, val & ~@as(u32, 1 << 16)); // интересная формула
    }
    fn disableIrq(self: *@This(), irq: u8) void {
        const lo_reg: u8 = 0x10 + irq * 2; // интересная формула.
        const val = self.readReg(lo_reg);
        self.writeReg(lo_reg, val | (1 << 16)); // интересная формула
    }
    // ---------------------------------------------------------------Wrappers--------------------------------------------
    fn mapIrqWrapper(ptr: *anyopaque, irq: u8, vector: u8, cpuid: u16) void {
        const self: *IOAPIC = @ptrCast(@alignCast(ptr));
        self.mapIrq(irq, vector, cpuid);
    }
    fn enableIrqWrapper(ptr: *anyopaque, irq: u8) void {
        const self: *IOAPIC = @ptrCast(@alignCast(ptr));
        self.enableIrq(irq);
    }
    fn disableIrqWrapper(ptr: *anyopaque, irq: u8) void {
        const self: *IOAPIC = @ptrCast(@alignCast(ptr));
        self.disableIrq(irq);
    }
};

pub const LAPIC = struct {
    base: *anyopaque,
    ticks_per_10ms: u64 = undefined,
    fn init(phys: u64) @This() {
        const base = vm.MMIOVMalloc.iomap(phys, 0x1000);
        var self: @This() = .{.base = base};
        self.write(0x0f0, 0x1ff); // 0x1ff -> 0x0f0 = enable
        self.write(0x320, 1 << 16); // masking irqs
        self.write(0x350, 1 << 16); // lint0
        self.write(0x360, 1 << 16); // lint1
        self.write(0x370, 1 << 16); // error
        return self;
    }
    pub fn calibrate(self: *LAPIC, hpet: *Hpet) void {
        self.write(0x3e0, 0x3); // 0x3 -> 0x3e0 = divide speed by 2 << 3 => divide speed by 16
        self.write(0x380, 0xFFFFFFFF); // 0xFFFFFFFF -> 0x380 = начальное значение счётчика в 0x380
        const start = hpet.getCurrentNs();
        while (hpet.getCurrentNs() - start < 10_000_000) {
            asm volatile ("pause");
        }
        const remaining = self.read(0x390); // 0x390 -> var = текущее значение счётчика
        const ticks_per_10ms = 0xFFFFFFFF - remaining;
        self.ticks_per_10ms = ticks_per_10ms;
    }
    pub fn eoi(self: *@This()) void {
        self.write(0x0b0, 0);
    }
    pub fn isHardwareInterrupt(vector: u8) bool {
        return vector >= 32;
    }
    pub fn setOneshot(self: *@This(), ns: u64) void {
        self.write(0x3e0, 0x3); // divider 16;
        self.write(0x320, 0x20020); // oneshot & vec 32 (0x20 at the start);
        self.write(0x380, @intCast(ns * self.ticks_per_10ms / 10_000_000));
    }
    pub fn setRepeating(self: *@This(), ns: u64) void {
        self.write(0x3e0, 0x3); // divider 16;
        self.write(0x320, 0x20020 | (1 << 17)); // repeating (periodic) & vec 32;
        self.write(0x380, @intCast(ns * self.ticks_per_10ms / 10_000_000));
    }
    pub fn stop(self: *@This()) void {
        self.write(0x320, 1 << 16); // mask
        self.write(0x380, 0);
    }

    // -----------------------------------------------------Utils---------------------------------------------------------

    fn write(self: *@This(), offset: u64, value: u32) void {
        const ptr: *volatile u32 = @ptrCast(@alignCast(addBytes(self.base, offset)));
        ptr.* = value;
    }
    fn read(self: *@This(), offset: u32) u32 {
        const ptr: *volatile u32 = @ptrCast(@alignCast(addBytes(self.base, offset)));
        return ptr.*;
    }

    // ----------------------------------------------------Wrappers---------------------------------------------------------------
    fn eoiWrapper(_: *anyopaque) void {
        lapic_instance.eoi();
    }
    fn setOneshotWrapper(ptr: *anyopaque, ns: u64) void {
        const self: *LAPIC = @ptrCast(@alignCast(ptr));
        self.setOneshot(ns);
    }
    fn setRepeatingWrapper(ptr: *anyopaque, ns: u64) void {
        const self: *LAPIC = @ptrCast(@alignCast(ptr));
        self.setRepeating(ns);
    }
    fn stopWrapper(ptr: *anyopaque) void {
        const self: *LAPIC = @ptrCast(@alignCast(ptr));
        self.stop();
    }
    fn isHardwareInterruptWrapper(_: *anyopaque, vector: u8) bool {
        return @This().isHardwareInterrupt(vector);
    }

};