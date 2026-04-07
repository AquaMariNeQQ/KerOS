use shared::memory::paging::{AddressSpace, ArchConfig, ArchSpecificPaging, MappingFlags};
use shared::{PhysAddr, VirtAddr};

pub struct X86Paging {
    root: u64
}

impl ArchSpecificPaging for X86Paging {
    const PAGE_SIZE: usize = 0;

    unsafe fn flush_tlb(&self, virt: VirtAddr) {
        todo!()
    }

    unsafe fn flush_tlb_all(&self) {
        todo!()
    }

    unsafe fn switch_to<E: ArchConfig>(space: AddressSpace<E>) {
        todo!()
    }
}

impl ArchConfig for X86Paging {
    const ADDR_MASK: u64 = 0x0000_FFFF_FFFF_FFF8;
    const SIGN_BIT: u8 = 47;
    const SHIFT: u8 = 40;
}

