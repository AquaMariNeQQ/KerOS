#![no_std]
#![no_main]
// #![deny(warnings)]

pub mod lists;
pub mod locks;
pub mod multicore;
pub mod sched;
pub mod memory;

use bitflags::bitflags;
use crate::multicore::AllocationSize;

#[repr(transparent)]
#[derive(Copy, Clone, PartialOrd, PartialEq, Ord, Eq)]
pub struct VirtAddr(u64);


impl Into<u64> for VirtAddr {
    fn into(self) -> u64 {
        self.as_u64()
    }
}

impl VirtAddr {
    pub fn new(addr: u64) -> Self {Self(addr)}

    pub unsafe fn write<T>(&self, obj: T) {
        let ptr = self.0 as *mut T;
        ptr.write_volatile(obj);
    }

    pub unsafe fn read<T>(&self) -> T {
        let ptr = self.0 as *mut T;
        ptr.read_volatile()
    }
    pub fn as_u64(&self) -> u64 {self.0}
}

#[repr(transparent)]
#[derive(Copy, Clone)]
pub struct PhysAddr(u64);

impl PhysAddr {
    pub fn new(addr: u64) -> Self {Self(addr)}

    pub unsafe fn write<T>(&self, obj: T) {
        let ptr = self.0 as *mut T;
        ptr.write_volatile(obj);
    }

    pub unsafe fn read<T>(&self) -> T {
        let ptr = self.0 as *mut T;
        ptr.read_volatile()
    }
    pub fn as_u64(&self) -> u64 {
        self.0
    }

    pub fn null() -> Self {
        Self(0)
    }
}

pub trait FrameAllocator {
    unsafe fn alloc(&mut self, size: AllocationSize) -> Option<PhysAddr>;
    unsafe fn dealloc(&mut self, addr: PhysAddr, size: AllocationSize);
}



pub trait PageTableProvider {
    fn map(&mut self, virt: VirtAddr, phys: PhysAddr, flags: PageFlags);
    fn unmap(&mut self, virt: VirtAddr);
    fn activate(&self); // загрузка в CR3 или аналог
}

bitflags!{
pub struct PageFlags: u64 {
        const PRESENT = 1 << 0;
        const WRITABLE = 1 << 1;
        const USER_ACCESSIBLE = 1 << 2;
        const NO_EXECUTE = 1 << 63;
    }
}

// shared/src/boot.rs

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum MemoryRegionKind {
    /// Свободная память, которую Buddy может забрать себе
    Usable,
    /// Зарезервировано железом (ACPI, BIOS, IO) — НЕ ТРОГАТЬ
    Reserved,
    /// Здесь лежит само ядро (уже занято)
    Kernel,
    /// Здесь лежат данные загрузчика (Multiboot/DTB)
    /// После инициализации это можно будет освободить
    BootloaderData,
    /// Дефектная память
    BadMemory,
}

#[derive(Debug, Clone, Copy)]
#[repr(C)]
pub struct MemoryRegion {
    pub start: u64,
    pub end: u64,
    pub kind: MemoryRegionKind,
}

pub struct BootInfo {
    /// Массив регионов. 64 должно хватить даже для фрагментированных систем.
    pub regions: [Option<MemoryRegion>; 64],
    /// Общий объем найденной памяти (для статистики)
    pub total_memory_bytes: u64,
    /// Информация для графического вывода (чтобы сразу видеть Panic)
    pub framebuffer: Option<FramebufferInfo>,

    /// Адрес структуры ACPI RSDP (на x86) или Device Tree (на ARM)
    /// Это "корень" для поиска всего железа (таймеры, прерывания, PCI)
    pub platform_config_ptr: Option<PhysAddr>,

    /// Командная строка ядра (например, "loglevel=debug init=/bin/init")
    pub cmdline: Option<&'static str>,
}


pub struct FramebufferInfo {
    pub addr: PhysAddr,
    pub width: u32,
    pub height: u32,
    pub bpp: u8,         // Bits per pixel (обычно 32)
    pub pitch: u32,       // Количество байт в одной строке (иногда != width * bpp)
    pub format: PixelFormat,
}

pub enum PixelFormat {
    Rgb,
    Bgr,
}

impl BootInfo {
    pub fn new() -> Self {
        Self {
            regions: [None; 64],
            total_memory_bytes: 0,
            framebuffer: None,
            platform_config_ptr: None,
            cmdline: None
        }
    }
    pub fn add_region(&mut self, start: u64, end: u64, kind: MemoryRegionKind) {
        if let Some(slot) = self.regions.iter_mut().find(|s| s.is_none()) {
            *slot = Some(MemoryRegion { start, end, kind });
            self.total_memory_bytes += end - start;
        } else {
            panic!();
        }
    }
}

pub trait BootSource {
    fn parse(ptr: PhysAddr) -> BootInfo;
}

pub trait Out {
    fn serial_println(text: &str);

    fn serial_println_hex(value: u64);
    unsafe fn serial_putc(c: u8);

    fn serial_print(text: &str);

    fn serial_print_hex(value: u64);

    fn serial_print_bool(value: bool);
    fn serial_println_bool(value: bool);
}