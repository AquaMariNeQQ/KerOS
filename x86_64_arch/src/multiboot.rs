use shared::{BootInfo, BootSource, FramebufferInfo, PhysAddr, PixelFormat};
use shared::MemoryRegionKind::{Kernel, Reserved, Usable};

#[repr(C, packed)]
pub struct Mb2InfoHeader {
    pub total_size: u32, // Общий размер всех тегов вместе с этим заголовком
    pub reserved: u32,   // Всегда 0
}

#[repr(C, packed)]
pub struct Mb2AcpiTag {
    pub typ: u32,  // 14 или 15
    pub size: u32,
    // Прямо здесь начинается копия структуры RSDP из памяти
    pub rsdp: [u8; 0],
}

#[repr(C, packed)]
pub struct RsdpV1 {
    pub signature: [u8; 8],     // Должно быть "RSD PTR "
    pub checksum: u8,           // Сумма всех байт должна быть 0
    pub oem_id: [u8; 6],
    pub revision: u8,           // 0 для v1.0
    pub rsdt_address: u32,      // Физический адрес таблицы RSDT
}

#[repr(C, packed)]
pub struct RsdpV2 {
    pub v1: RsdpV1,             // Включает в себя все поля v1
    pub length: u32,            // Весь размер структуры
    pub xsdt_address: u64,      // 64-битный физический адрес XSDT (КЛЮЧЕВОЙ ПОЛЕ)
    pub extended_checksum: u8,
    pub reserved: [u8; 3],
}

#[repr(C, packed)]
pub struct Mb2MemoryMapTag {
    pub typ: u32,       // 6
    pub size: u32,
    pub entry_size: u32, // Размер одной записи (обычно 24)
    pub entry_version: u32,
    // Далее идут записи (Mb2MemoryArea) до конца size
}

#[repr(C, packed)]
pub struct Mb2MemoryArea {
    pub base_addr: u64,
    pub length: u64,
    pub typ: u32, // 1 = Available, остальное = Reserved
    pub reserved: u32,
}

#[repr(C, packed)]
pub struct Mb2FramebufferTag {
    pub typ: u32,
    pub size: u32,
    pub addr: u64,
    pub pitch: u32,
    pub width: u32,
    pub height: u32,
    pub bpp: u8,
    pub framebuffer_type: u8, // 0 = Indexed, 1 = RGB
    pub reserved: u16,

    // Эти поля появляются, если framebuffer_type == 1
    pub red_field_position: u8,
    pub red_field_size: u8,
    pub green_field_position: u8,
    pub green_field_size: u8,
    pub blue_field_position: u8,
    pub blue_field_size: u8,
}

#[repr(C, packed)]
struct Mb2Tag {
    typ: u32,
    size: u32,
}

pub struct Multiboot2Source {}

impl BootSource for Multiboot2Source {
    fn parse(ptr: PhysAddr) -> BootInfo {
        unsafe { parse_mbt(ptr) }
    }
}

pub unsafe fn parse_mbt(ptr: PhysAddr) -> BootInfo {
    let ptr = ptr.as_u64();
    let header = ptr as *const Mb2InfoHeader;
    let total_size = (*header).total_size;
    let mut boot_info = BootInfo::new();
    let mut offset: u32 = 8;
    while offset < total_size {
        let tag_ptr = (ptr + offset as u64) as *const Mb2Tag;
        let tag = &*tag_ptr;
        if tag.size == 8 && tag.typ == 0 { break };
        match tag.typ {
            1 => { /*cmd*/ },
            6 => {
                let mem_tag = &*(tag_ptr as *const Mb2MemoryMapTag);
                let entry_size = mem_tag.entry_size;
                let entries = ((*mem_tag).size - 16) / entry_size;
                let mut current_entry_ptr = (tag_ptr as u64 + 16) as *const Mb2MemoryArea;
                for _ in 0..entries {
                    let area = &*current_entry_ptr;
                    let a_start = area.base_addr;
                    // Теперь у тебя есть чистые адреса:
                    let a_end = a_start + area.length;
                    let k_start = unsafe { &__kernel_start as *const u8 as u64 };
                    let k_end = unsafe { &__kernel_end as *const u8 as u64 };
                    if area.typ == 1 {
                        let overlap_start = u64::max(a_start, k_start);
                        let overlap_end = u64::min(a_end, k_end);
                        if overlap_start < overlap_end {
                            if a_start < k_start {
                                boot_info.add_region(a_start, k_start, Usable);
                            }
                            boot_info.add_region(overlap_start, overlap_end, Kernel);
                            if a_end > k_end {
                                boot_info.add_region(k_end, a_end, Usable);
                            }
                        } else { boot_info.add_region(a_start, a_end, Usable) }
                    } else {
                        boot_info.add_region(a_start, a_end, Reserved);
                    }
                    current_entry_ptr = (current_entry_ptr as u64 + entry_size as u64) as *const Mb2MemoryArea;

                }
            },
            8 => {
                let fb = &*(tag_ptr as *const Mb2FramebufferTag);
                boot_info.framebuffer = Some(FramebufferInfo {
                    addr: PhysAddr::new(fb.addr),
                    width: fb.width,
                    height: fb.height,
                    bpp: fb.bpp,
                    pitch: fb.pitch,
                    format: if fb.red_field_position == 0 { PixelFormat::Rgb } else { PixelFormat::Bgr },
                });
            },
            14 | 15 => {
                let rsdt_ptr = tag_ptr as u64 + 8; // 8 = typ + size
                validate_rsdp(rsdt_ptr as *const RsdpV2);
                boot_info.platform_config_ptr = Some(PhysAddr::new(rsdt_ptr));
            },
            _ => { /*who da fuck cares?*/ }
        }
        offset += (tag.size + 7) & !7
    }
    boot_info
}


extern "C" {
    static __kernel_start: u8;
    static __kernel_end: u8;
}

pub fn get_kernel_address_range() -> (u64, u64) {
    unsafe {
        (
            &__kernel_start as *const u8 as u64,
            &__kernel_end as *const u8 as u64
        )
    }
}

// Пример логики в x86_64_arch/acpi.rs

pub fn validate_rsdp(ptr: *const RsdpV2) {
    let rsdp = unsafe { &*ptr };

    // 1. Проверяем сигнатуру "RSD PTR " (8 байт)
    if &rsdp.v1.signature != b"RSD PTR " {
        panic!("ACPI Error: Invalid RSDP signature! Found: {:?}", rsdp.v1.signature);
    }

    // 2. Проверяем базовую чексумму (v1)
    if !verify_checksum(ptr as *const u8, 20) {
        panic!("ACPI Error: RSDP v1 checksum failed!");
    }

    // 3. Если это v2, проверяем расширенную чексумму
    if rsdp.v1.revision >= 2 {
        if !verify_checksum(ptr as *const u8, rsdp.length as usize) {
            panic!("ACPI Error: RSDP v2 extended checksum failed!");
        }
    }
}

fn verify_checksum(ptr: *const u8, len: usize) -> bool {
    let mut sum: u8 = 0;
    for i in 0..len {
        unsafe {
            // wrapping_add — это стандартный способ в Rust сказать:
            // "Я знаю про переполнение, так и задумано"
            sum = sum.wrapping_add(*ptr.add(i));
        }
    }
    sum == 0
}