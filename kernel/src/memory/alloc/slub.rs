use crate::arch::CurrentData;
use crate::memory::alloc::buddy::{CpuLocalBuddyAllocator, MAX_CHUNKS};
use crate::memory::alloc::multicore::CPU_DATA;
use crate::memory::alloc::{get_addr_from_page, get_page, ALLOCATOR, PHYS_OFFSET};
use core::ptr::null_mut;
use core::sync::atomic::{AtomicPtr, Ordering};
use shared::lists::intrusive_linked_list::{IntrusiveList, List};
use shared::multicore::AllocationSize::_4KB;
use shared::multicore::{AllocationSize, ArchSpecific, CpuLocalAllocator, Page};
use shared::{MemoryRegion, PhysAddr, VirtAddr};

pub struct SlubAllocator {
    /// Caches for objects 8B..2KB
    caches: [SlabCache; 9],
    /// CPU ID
    cpu_id: u8,
    /// Chunks link; to the ALLOCATOR's field
    chunks: *const [*mut Page; MAX_CHUNKS],
    /// For deallocing from the other cores
    remote_free_heads: [AtomicPtr<u64>; 9],
}
pub struct SlabCache {
    /// Current page
    active_page: *mut Page, // Текущая страница, откуда берем объекты
    /// Free object list inside the current page
    free_list: *mut u64,    // Указывает на свободный объект ВНУТРИ active_page
    /// Partially used pages.
    partial_pages: IntrusiveList<Page>, // Страницы, где есть свободные места
    /// Free pages AMOUNT (for stats)
    free_pages: u16,
    /// Object size ( = 1 << cache index + 3)
    obj_size: usize,
}

impl SlabCache {
    pub const fn new(size: usize) -> Self {
        Self {
            active_page: null_mut(),
            free_list: null_mut(),
            partial_pages: const {IntrusiveList::new()},
            free_pages: 0,
            obj_size: size,
        }
    }
}
impl SlubAllocator {
    unsafe fn collect_remote(&mut self) {
        let mut lists: [*mut u64; 9] = [null_mut(); 9];
        for (index, head) in self.remote_free_heads.iter_mut().enumerate() {
            lists[index] = head.swap(null_mut(), Ordering::Acquire);
        }
        for (idx, mut curr_obj) in lists.into_iter().enumerate() {
            while !curr_obj.is_null() {
                let next_obj = *curr_obj as *mut u64;
                let phys_addr = (curr_obj as u64) - PHYS_OFFSET;
                let page = get_page(&*self.chunks, phys_addr);
                let old_usage = (*page).usage;
                (*page).usage -= 1;
                let cache = &mut self.caches[idx];
                if page == cache.active_page {
                    *curr_obj = cache.free_list as u64;
                    cache.free_list = curr_obj;
                } else {
                    *curr_obj = (*page).free_list_head;
                    (*page).free_list_head = curr_obj as u64;
                }
                let max_objs = (4096 / cache.obj_size) as u16;
                if old_usage == max_objs && page != cache.active_page {
                    cache.partial_pages.push_back(page);
                }
                if (*page).usage == 0 {
                    // CurrentOut::serial_print("[");
                    // CurrentOut::serial_print_hex(cache.obj_size as u64);
                    // CurrentOut::serial_print("]: CR: FP += ");
                    // CurrentOut::serial_println_hex(cache.free_pages as u64);
                    cache.free_pages += 1;
                }
                curr_obj = next_obj;
            }
        }
    }
    unsafe fn refill(&mut self, order: u8) {
        // CurrentOut::serial_println("Y1");
        self.collect_remote();
        // CurrentOut::serial_println("Y2");
        let cache = &mut self.caches[order as usize];
        // CurrentOut::serial_println("Y4");
        if cache.free_list.is_null() {
            // todo: try getting something from the partial pages
            if !cache.partial_pages.is_empty() {
                // CurrentOut::serial_println("Y6");
                let page = cache.partial_pages.pop_front();
                let page_list = (*page).free_list_head;
                cache.free_list = page_list as *mut u64;
                cache.active_page = page;
                (*page).free_list_head = 0;
                //  if got - return; if not - --->
            } else {
                // CurrentOut::serial_println("Y7");
                let cpudata = CurrentData::get_per_cpu::<CpuLocalBuddyAllocator, SlubAllocator>();
                assert!(!cpudata.is_null(), "### PerCPU Data address is NULL ###");
                if let Some(allocated) = (*cpudata).local_buddy.alloc(_4KB) {
                    // CurrentOut::serial_print("[");
                    // CurrentOut::serial_print_hex(cache.obj_size as u64);
                    // CurrentOut::serial_print("]: RF: FP += ");
                    // CurrentOut::serial_println_hex(cache.free_pages as u64);
                    cache.free_pages += 1;
                    let page = get_page(&*self.chunks, allocated.as_u64());
                    if page.is_null() { return; }
                    (*page).usage = 0;
                    (*page).free_list_head = 0;
                    let obj_amount = 4096 / cache.obj_size;
                    let base_addr = allocated.as_u64() + PHYS_OFFSET;
                    for obj in 0..obj_amount { // 4096 - page size; 4096 / cache.obj_size = obj_amount
                        let obj_addr = base_addr as usize + obj*cache.obj_size;
                        *(obj_addr as *mut u64) = (*page).free_list_head;
                        (*page).free_list_head = obj_addr as u64;
                    }
                    cache.free_list = (*page).free_list_head as *mut u64;
                    cache.active_page = page;
                    (*page).free_list_head = 0;
                }
            }
        }
    }
    unsafe fn send_remote(&mut self, object: *mut u64, page: *mut Page, object_order: usize) {
        let target_data = CPU_DATA[(*page).owner_id as usize];
        assert_ne!(target_data, null_mut(), "Null pointer still-not-dereference in send_remote, please explain how TF did it (and by it, I mean ownerId to non-existent structure) end up here?");
        let target_list = &(*target_data).local_slub.remote_free_heads[object_order];
        let mut current_head = target_list.load(Ordering::Relaxed);
        loop {
            *object = current_head as u64;
            match target_list.compare_exchange_weak(
                current_head,
                object,
                Ordering::Release,
                Ordering::Relaxed
            ) {
                Ok(_) => break,
                Err(new_head) => current_head = new_head,
            }
        }
    }
}

impl CpuLocalAllocator for SlubAllocator {
    unsafe fn alloc(&mut self, size: AllocationSize) -> Option<PhysAddr> {
        let size = size as u8;
        assert!(size < 9, "Slub: tried to alloc >2kB block");
        if self.caches[size as usize].free_list.is_null() {
            self.refill(size);
        }
        let cache = &mut self.caches[size as usize];
        let obj = cache.free_list;
        if !obj.is_null() {
            if (*cache.active_page).usage == 0 {
                // Внутри alloc, после obj.is_null()
                let actual_page = get_page(&*self.chunks, (obj as u64) - PHYS_OFFSET);
                // if actual_page != cache.active_page {
                    // CurrentOut::serial_print("!DIFF! OBJ_PG:");
                    // CurrentOut::serial_print_hex(actual_page as u64);
                    // CurrentOut::serial_print(" ACT_PG:");
                    // CurrentOut::serial_println_hex(cache.active_page as u64);
                // }

                (*actual_page).usage += 1; // Инкрементируй ВСЕГДА ту страницу, которой принадлежит объект
                cache.free_pages -= 1;
            }
            (*cache.active_page).usage += 1;
            cache.free_list = *obj as *mut u64;
            Some(PhysAddr::new((obj as u64) - PHYS_OFFSET))
        } else {
            None
        }
    }

    unsafe fn dealloc(&mut self, addr: PhysAddr, size: AllocationSize) {
        assert!((size as u8) < 9, "SlubAllocator: attempted to deallocate a Buddy-sized block!");
        let page = get_page(&*self.chunks, addr.as_u64());
        if !page.is_null() {
            let cache = &mut self.caches[size as usize];
            if (*page).owner_id != self.cpu_id {
                self.send_remote((addr.as_u64() + PHYS_OFFSET) as *mut u64, page, size as usize);
                return;
            } else {
                // put it in the corresponding cache, decrease active page's usage, check if it's free, maybe modify free_pages
                if page == cache.active_page {
                    *((addr.as_u64() + PHYS_OFFSET) as *mut u64) = cache.free_list as u64;
                    cache.free_list = (addr.as_u64() + PHYS_OFFSET) as *mut u64;
                } else {
                    *((addr.as_u64() + PHYS_OFFSET) as *mut u64) = (*page).free_list_head;
                    (*page).free_list_head = addr.as_u64() + PHYS_OFFSET;
                }
                let old_usage = (*page).usage;
                let max_objs = 4096 / cache.obj_size as u16;
                (*page).usage -= 1;
                if old_usage == max_objs && page != cache.active_page {
                    cache.partial_pages.push_back(page);
                }
                if (*page).usage == 0 {
                    // CurrentOut::serial_print("[");
                    // CurrentOut::serial_print_hex(cache.obj_size as u64);
                    // CurrentOut::serial_print("]: DAL1: FP += ");
                    // CurrentOut::serial_println_hex(cache.free_pages as u64);
                    cache.free_pages += 1;
                }
            }
            if cache.free_pages >= 8 {
                let mut page = cache.partial_pages.lookup_front();
                while !page.is_null() && cache.free_pages > 2 {
                    let next = (*page).list_node.next;
                    if (*page).usage == 0 && page != cache.active_page {
                        cache.partial_pages.remove(page);
                        // CurrentOut::serial_print("[");
                        // CurrentOut::serial_print_hex(cache.obj_size as u64);
                        // CurrentOut::serial_print("]: DAL2: FP -= ");
                        // CurrentOut::serial_println_hex(cache.free_pages as u64);
                        cache.free_pages -= 1;
                        let phys_addr = get_addr_from_page(page, &*self.chunks);
                        (*CurrentData::get_per_cpu::<CpuLocalBuddyAllocator, SlubAllocator>()).local_buddy.dealloc(phys_addr, _4KB);
                    }
                    page = next;
                }
                // free 6 (or more, depending on how many there are, but it's somewhere about 3 / 4) of them to the buddy
            }
        }
    }
    unsafe fn alloc_virtual(&mut self, size: AllocationSize) -> Option<VirtAddr> {
        let allocd = self.alloc(size);
        if allocd.is_none() { None } else { Some(VirtAddr::new(allocd.unwrap().as_u64() + PHYS_OFFSET)) }
    }

    unsafe fn dealloc_virtual(&mut self, ptr: VirtAddr, size: AllocationSize) {
        self.dealloc(PhysAddr::new(ptr.as_u64() - PHYS_OFFSET), size);
    }

    unsafe fn add_region(&mut self, _: MemoryRegion) -> Result<(), &'static str> {
        unimplemented!();
    }

    fn new(cpu_id: u8) -> Self {
        let metadata_chunks = ALLOCATOR.lock().get_chunks_ptr();
        Self {
            caches: [
                SlabCache::new(8),    // _8B
                SlabCache::new(16),   // _16B
                SlabCache::new(32),   // _32B
                SlabCache::new(64),   // _64B
                SlabCache::new(128),  // _128B
                SlabCache::new(256),  // _256B
                SlabCache::new(512),  // _512B
                SlabCache::new(1024), // _1KB
                SlabCache::new(2048), // _2KB
            ],
            cpu_id,
            chunks: metadata_chunks,
            remote_free_heads: [const {AtomicPtr::null()}; 9],
        }
    }
}
