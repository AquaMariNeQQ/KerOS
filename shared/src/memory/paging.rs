use bitflags::bitflags;
use crate::{FrameAllocator, PhysAddr, VirtAddr};
use crate::memory::virtual_memory::VMMRadixTree;

pub struct AddressSpace<E: ArchConfig> {
    /// Физический адрес корня (например, PML4)
    pub root: PhysAddr,
    pub tree: VMMRadixTree<E>
}

pub trait ArchSpecificAddressSpace<A: FrameAllocator> {
    /// Маппинг диапазона. Возвращает ошибку, если маппинг уже существует.
    unsafe fn map_range(&mut self, virt: VirtAddr, phys: PhysAddr, size: usize, flags: MappingFlags, alloc: &mut A) -> Result<(), PagingError>;

    /// Разрыв маппинга диапазона.
    unsafe fn unmap_range(&mut self, virt: VirtAddr, size: usize, alloc: &mut A) -> Result<(), PagingError>;

    /// Изменение флагов для существующего диапазона (например, для mprotect).
    unsafe fn remap_range(&mut self, virt: VirtAddr, size: usize, new_flags: MappingFlags, alloc: &mut A) -> Result<(), PagingError>;

    /// Переводит виртуальный адрес в физический (Walk по таблицам)
    fn translate(&self, virt: VirtAddr) -> Option<PhysAddr>;

    fn get_root_phys(&self) -> PhysAddr;
}

pub trait ArchSpecificPaging {
    const PAGE_SIZE: usize;
    /// Сброс TLB для конкретного адреса (invlpg).
    unsafe fn flush_tlb(&self, virt: VirtAddr);

    /// Полный сброс TLB.
    unsafe fn flush_tlb_all(&self);

    /// Активация адресного пространства (загрузка корня в регистр управления).
    unsafe fn switch_to<E: ArchConfig>(space: AddressSpace<E>);
}

pub trait ArchConfig {
    const ADDR_MASK: u64;
    const SIGN_BIT: u8;
    const SHIFT: u8;
}

bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct MappingFlags: u32 {
        const WRITABLE         = 1 << 1;
        const USER_ACCESSIBLE  = 1 << 2;
        const WRITE_THROUGH    = 1 << 3; // Для работы с видеопамятью/устройствами
        const NO_CACHE         = 1 << 4;
        const ACCESSED         = 1 << 5;
        const DIRTY            = 1 << 6;
        const HUGE_PAGE_2MB    = 1 << 7; // 2MiB или 1GiB
        const HUGE_PAGE_1GB    = 1 << 8; // 2MiB или 1GiB
        const GLOBAL           = 1 << 9;
        const EXECUTABLE       = 1 << 31; // NX-бит (нужен EFER.NXE)
    }
}

pub enum PagingError {
    OutOfMemory,
    Overlap,
    NotFound,
    InvalidAlignment,
    NotSupported,
}