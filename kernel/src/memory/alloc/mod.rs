use core::alloc::{GlobalAlloc, Layout};
use core::ptr::null_mut;
use shared::locks::Spinlock;
use shared::multicore::{AllocationSize, ArchSpecific, CpuLocalAllocator, Page};
use shared::{FrameAllocator, PhysAddr};
use crate::arch::CurrentData;
use crate::memory::alloc::buddy::{BuddyAllocator, CpuLocalBuddyAllocator, MAX_CHUNKS, PAGES_PER_CHUNK};
use crate::memory::alloc::slub::SlubAllocator;

pub mod buddy;
pub mod slub;
pub mod multicore;

pub static ALLOCATOR: Spinlock<BuddyAllocator> = Spinlock::new(BuddyAllocator::new());

pub static mut PHYS_OFFSET: u64 = 0;

pub unsafe fn get_page(chunks: &[*mut Page; MAX_CHUNKS], phys_addr: u64) -> *mut Page {
    let phys_addr = phys_addr & !4095;
    let chunk_idx: u64 = phys_addr / (PAGES_PER_CHUNK*4096) as u64;
    let page_idx = (phys_addr / 4096) as usize % PAGES_PER_CHUNK;
    let chunk = chunks[chunk_idx as usize];
    if chunk.is_null() { return null_mut(); }
    chunk.add(page_idx)
}

pub unsafe fn get_addr_from_page(page: *mut Page, list: &[*mut Page; MAX_CHUNKS]) -> PhysAddr {
    let metadata_base = list[(*page).chunk as usize];
    let page_idx_in_chunk = (page as usize - metadata_base as usize) / size_of::<Page>();
    let chunk_start = (*page).chunk as usize * PAGES_PER_CHUNK * 4096;
    let page_addr = chunk_start + page_idx_in_chunk * 4096;
    PhysAddr::new(page_addr as u64)
}

struct Alloc;

unsafe impl GlobalAlloc for Alloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let size = layout.size().max(layout.align()).max(8);
        let alloc_size = AllocationSize::from_size(size, layout.align());
        let per_cpu_ptr = CurrentData::get_per_cpu::<CpuLocalBuddyAllocator, SlubAllocator>();
        if per_cpu_ptr.is_null() {
            return match ALLOCATOR.lock().alloc(alloc_size) {
                Some(addr) => (addr.as_u64() + PHYS_OFFSET) as *mut u8,
                None => null_mut(),
            };
        }
        let per_cpu = &mut *per_cpu_ptr;
        // 3. Иерархическая аллокация
        let result = if size <= 2048 {
            // Маленькие объекты -> SLUB
            per_cpu.local_slub.alloc(alloc_size)
        } else if size <= 16384 {
            // Средние объекты -> Local Buddy (без глобального лока)
            per_cpu.local_buddy.alloc(alloc_size)
        } else {
            // Крупные объекты -> Глобальный Buddy (с локом)
            ALLOCATOR.lock().alloc(alloc_size)
        };

        match result {
            Some(addr) => (addr.as_u64() + PHYS_OFFSET) as *mut u8,
            None => null_mut(),
        }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        if ptr.is_null() { return; }

        let phys_addr = PhysAddr::new(ptr as u64 - PHYS_OFFSET);
        let size = layout.size().max(layout.align());
        let alloc_size = AllocationSize::from_size(size, layout.align());

        // 1. Получаем доступ к PerCpuData
        // ВАЖНО: Если мы не выключаем прерывания, планировщик может перекинуть
        // нас на другое ядро ПРЯМО ТУТ. Но для деаллокации в SLUB это не страшно,
        // так как у тебя есть механизм remote_free_heads.

        let per_cpu_ptr = CurrentData::get_per_cpu::<CpuLocalBuddyAllocator, SlubAllocator>();

        if per_cpu_ptr.is_null() {
            ALLOCATOR.lock().dealloc(phys_addr, alloc_size);
            return;
        }

        let per_cpu = &mut *per_cpu_ptr;

        if size <= 2048 {
            per_cpu.local_slub.dealloc(phys_addr, alloc_size);
        } else if size <= 16384 {
            per_cpu.local_buddy.dealloc(phys_addr, alloc_size);
        } else {
            ALLOCATOR.lock().dealloc(phys_addr, alloc_size);
        }
    }
}
#[global_allocator]
static GLOBAL: Alloc = Alloc;