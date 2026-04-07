use crate::memory::alloc::multicore::CPU_DATA;
use crate::memory::alloc::{get_addr_from_page, get_page, ALLOCATOR, PHYS_OFFSET};
use crate::println;
use core::cmp::min;
use core::ptr::{null_mut, write_bytes};
use core::sync::atomic::{AtomicPtr, Ordering};
use shared::lists::intrusive_linked_list::{IntrusiveList, List};
use shared::multicore::AllocationSize;
use shared::multicore::AllocationSize::{_4KB, _4MB};
use shared::multicore::AllocatorPageFlags;
use shared::multicore::CpuLocalAllocator;
use shared::multicore::Page;
use shared::{FrameAllocator, MemoryRegion, MemoryRegionKind, PhysAddr, VirtAddr};

pub const MAX_CHUNKS: usize = 4096; // 1TB ram max
pub const BOOT_MAPPING_SIZE: usize = 1024*1024*1024; // 1TB ram max
pub const BUDDY_LEVELS: usize = 11; // 1TB ram max
pub const PAGES_PER_CHUNK: usize = 131072; // 512MB

pub struct BuddyAllocator {
    free_lists: [IntrusiveList<Page>; BUDDY_LEVELS],
    // Вместо одного указателя — массив чанков метаданных
    pub chunks: [*mut Page; MAX_CHUNKS],
    pub _total_pages: usize,
}
pub struct CpuLocalBuddyAllocator {
    // Списки свободных страниц, которыми ВЛАДЕЕТ этот CPU
    free_lists: [IntrusiveList<Page>; BUDDY_LEVELS],

    // Ссылка на таблицу чанков (чтобы не копировать 32КБ)
    // Можно хранить просто указатель на массив из BuddyAllocator
    metadata_chunks: *const [*mut Page; MAX_CHUNKS],

    free_pages_count: usize,
    cpu_id: u8,

    // Сюда другие ядра "подбрасывают" страницы, которые были выделены здесь,
    // но освобождены там.
    remote_free_list: AtomicPtr<Page>,
}

impl BuddyAllocator {
    pub fn get_chunks_ptr(&self) -> *const [*mut Page; MAX_CHUNKS] {
        &self.chunks as *const _
    }
    unsafe fn add_region(&mut self, region: MemoryRegion) -> Result<(), &'static str> {
        if region.kind != MemoryRegionKind::Usable { return Err("Non-usable memory region passed to add_region!!"); }
        let mut reg_ptr = (region.start + 4095) & !4095;
        let end = region.end & !4095;
        while reg_ptr < end {
            let align_order = (reg_ptr.trailing_zeros() - 12).max(0);
            let distance_order = ((end - reg_ptr).ilog2() - 12).max(0);
            let order = min(distance_order, align_order).min(10);
            let page = get_page(&self.chunks, reg_ptr);
            if !page.is_null() {
                (*page).order = order as u8;
                (*page).magic = 0x4B334F53;
                (*page).owner_id = 0;
                (*page).flags = AllocatorPageFlags::IsFree | AllocatorPageFlags::NoOwner;
                self.free_lists[order as usize].push_front(page);
            } else {
                return Err("Chunk metadata not initialized!");
            }
            reg_ptr += 1 << (order + 12)

        }
        Ok(())
    }
    pub const fn new() -> Self {
        Self {
            free_lists: [const {IntrusiveList::new()}; BUDDY_LEVELS],
            chunks: [null_mut(); MAX_CHUNKS],
            _total_pages: 0,
        }
    }
}
impl FrameAllocator for BuddyAllocator {
    unsafe fn alloc(&mut self, order: AllocationSize) -> Option<PhysAddr> {
        assert!((order as u8) >= _4KB as u8, "Tried to allocate slub-sized block from buddy!");
        for current_order in order.clone().to_buddy_size()..=_4MB.to_buddy_size() {
            if !self.free_lists[current_order as usize].is_empty() {
                let page = self.free_lists[current_order as usize].pop_front();
                if (*page).magic == 0x4B334F53 && (*page).flags.contains(AllocatorPageFlags::NoOwner) {
                    for split_order in (order.clone().to_buddy_size()..current_order).rev() {
                        let sec_page = page.add(1 << split_order);
                        (*sec_page).order = split_order;
                        (*sec_page).flags.insert(AllocatorPageFlags::IsFree | AllocatorPageFlags::NoOwner);
                        (*sec_page).magic = 0x4B334F53;
                        self.free_lists[split_order as usize].push_back(sec_page);
                    }
                    (*page).flags.remove(AllocatorPageFlags::NoOwner | AllocatorPageFlags::IsFree);
                    (*page).order = order.to_buddy_size();
                    return Some(get_addr_from_page(page, &self.chunks));
                }
            }
        }
        None
    }

    unsafe fn dealloc(&mut self, addr: PhysAddr, size: AllocationSize) {
        // get the first block
        assert!((size as u8) >= _4KB as u8, "BuddyAllocator: attempted to deallocate a Slub-sized block!");
        let mut current_pfn = addr.as_u64() / 4096;
        let order = size.to_buddy_size();
        let mut final_order = order;
        for current_order in order.._4MB.to_buddy_size() {
            let buddy_pfn = current_pfn ^ (1 << current_order as u32);
            let buddy_ptr = get_page(&self.chunks, buddy_pfn * 4096);
            if buddy_ptr == null_mut() { break; }
            if (*buddy_ptr).flags.contains(AllocatorPageFlags::IsFree | AllocatorPageFlags::NoOwner)
                && (*buddy_ptr).order == current_order && (*buddy_ptr).magic == 0x4B334F53
            {
                self.free_lists[current_order as usize].remove(&mut *buddy_ptr);
                (*buddy_ptr).flags.remove(AllocatorPageFlags::IsFree);
                current_pfn &= !(1 << current_order);
                final_order = current_order + 1;
            } else {
                break;
            }
        }
        let final_page_ptr = get_page(&self.chunks,current_pfn * 4096);
        if !final_page_ptr.is_null() {
            (*final_page_ptr).flags.insert(AllocatorPageFlags::IsFree | AllocatorPageFlags::NoOwner);
            (*final_page_ptr).order = final_order;
            (*final_page_ptr).magic = 0x4B334F53;
            self.free_lists[final_order as usize].push_front(final_page_ptr)
        }
    }
}

impl CpuLocalBuddyAllocator {
    unsafe fn collect_from_remote_list(&mut self) {
        let mut head = self.remote_free_list.swap(null_mut(), Ordering::Acquire);
        while !head.is_null() {
            let next = (*head).list_node.next;
            assert_eq!((*head).magic, 0x4B334F53);
            let order = (*head).order;
            self.free_pages_count += 1 << order;
            self.internal_free(head);
            head = next;
        }
    }
    unsafe fn internal_free(&mut self, page: *mut Page) {
        let mut final_order = (*page).order;
        let mut current_pfn = get_addr_from_page(page, &*self.metadata_chunks).as_u64() / 4096;
        for current_order in (*page).order.._4MB.to_buddy_size() {
            let buddy_pfn = current_pfn ^ (1 << current_order as u32);
            let buddy_ptr = get_page(&*self.metadata_chunks, buddy_pfn * 4096);
            if buddy_ptr == null_mut() { break; }
            if (*buddy_ptr).flags.contains(AllocatorPageFlags::IsFree) && (*buddy_ptr).owner_id == self.cpu_id
                && (*buddy_ptr).order == current_order && (*buddy_ptr).magic == 0x4B334F53
            {
                self.free_lists[current_order as usize].remove(&mut *buddy_ptr);
                (*buddy_ptr).flags.remove(AllocatorPageFlags::IsFree);
                current_pfn &= !(1 << current_order);
                final_order = current_order + 1;
            } else {
                break;
            }
        }
        let final_page_ptr = get_page(&*self.metadata_chunks,current_pfn * 4096);
        if !final_page_ptr.is_null() {
            (*final_page_ptr).flags.insert(AllocatorPageFlags::IsFree);
            (*final_page_ptr).owner_id = self.cpu_id;
            (*final_page_ptr).order = final_order;
            (*final_page_ptr).magic = 0x4B334F53;
            self.free_lists[final_order as usize].push_front(final_page_ptr)
        }
    }
    unsafe fn refill(&mut self, target: AllocationSize) {
        // fast way
        self.collect_from_remote_list();
        let mut any_full = false;
        for i in (target.to_buddy_size() as usize)..BUDDY_LEVELS {
            if !self.free_lists[i].is_empty() {any_full = true; break;};
        }
        if any_full { return; }
        // slow way
        {
            let mut addrs: [Option<PhysAddr>; 4] = [None; 4];
            let mut is_success = false;
            let mut current_order = _4MB as u8;
            {
                let mut alloc = ALLOCATOR.lock();
                for order in (_4KB.to_buddy_size()..=_4MB.to_buddy_size()).rev() {
                    for i in 0..4 {
                        let maybe_addr = alloc.alloc(AllocationSize::from_buddy_order(order));
                        if maybe_addr.is_none() { break; } else { is_success = true; }
                        addrs[i] = maybe_addr;
                    }
                    if is_success {
                        current_order = order + _4KB as u8;
                        break;
                    }
                }
            }
            if is_success {
                for addr in addrs {
                    if let Some(address) = addr {
                        let page = get_page(&*self.metadata_chunks, address.as_u64());
                        let pages_in_block = 1 << (current_order - (_4KB as u8));
                        for i in 0..pages_in_block {
                            let p = page.add(i);
                            (*p).magic = 0x4B334F53;
                            (*p).owner_id = self.cpu_id;
                            (*p).flags.remove(AllocatorPageFlags::IsFree | AllocatorPageFlags::NoOwner);
                        }
                        self.free_pages_count += pages_in_block;
                        (*page).flags.insert(AllocatorPageFlags::IsFree);
                        let order_idx = (current_order - _4KB as u8)as usize;
                        (*page).order = order_idx as u8;
                        self.free_lists[order_idx].push_front(page);
                    }
                }
            }
        }
    }
    unsafe fn return_page(chunks: &[*mut Page; MAX_CHUNKS], addr: *mut Page) -> u16 {
        let final_order = (*addr).order;
        // return this page to the global buddy;
        (*addr).owner_id = 0;
        let page_addr = get_addr_from_page(addr, chunks);
        let order = (*addr).order;
        debug_assert!(page_addr.as_u64() % (1 << ((*addr).order + 12)) == 0);
        for i in 0..(1 << order) {
            let p = addr.add(i as usize);
            (*p).owner_id = 0;
            (*p).flags = AllocatorPageFlags::IsFree | AllocatorPageFlags::NoOwner;
        }
        ALLOCATOR.lock().dealloc(page_addr, AllocationSize::from_buddy_order(final_order));
        1 << final_order
    }
    unsafe fn send_remote(&mut self, page: *mut Page) {
        let owner_id = (*page).owner_id;
        let target_data = CPU_DATA[owner_id as usize];
        assert_ne!(target_data, null_mut(), "Null pointer still-not-dereference in send_remote, please explain how TF did it (and by it, I mean ownerId to non-existent structure) end up here?");
        let target_list = &(*target_data).local_buddy.remote_free_list;
        let mut current_head = target_list.load(Ordering::Relaxed);
        loop {
            (*page).list_node.next = current_head;
            match target_list.compare_exchange_weak(
                current_head,
                page,
                Ordering::Release,
                Ordering::Relaxed
            ) {
                Ok(_) => break,
                Err(new_head) => current_head = new_head,
            }
        }
    }
}

unsafe fn get_buddy(chunks: &[*mut Page; MAX_CHUNKS], page: *mut Page) -> *mut Page {
    let current_pfn = get_addr_from_page(page, chunks).as_u64() / 4096;
    let buddy_pfn = current_pfn ^ (1 << (*page).order as u32);
    get_page(chunks, buddy_pfn * 4096)
}



impl CpuLocalAllocator for CpuLocalBuddyAllocator {
    unsafe fn alloc(&mut self, order: AllocationSize) -> Option<PhysAddr> {
        assert!((order as u8) >= _4KB as u8, "Tried to allocate slub-sized block from buddy!");
        let mut any_full = false;
        for i in (order.to_buddy_size() as usize)..BUDDY_LEVELS {
            if !self.free_lists[i].is_empty() {any_full = true; break;};
        }
        if !any_full { self.refill(order) }
        for current_order in order.clone().to_buddy_size()..=_4MB.to_buddy_size() {
            if !self.free_lists[current_order as usize].is_empty() {

                let page = self.free_lists[current_order as usize].pop_front();
                assert_eq!((*page).owner_id, self.cpu_id, "WHY DA FUCK DID YOU TRY TO ALLOCATE SOMEBODY ELSE'S MEMORY?");
                if (*page).magic == 0x4B334F53 && !(*page).flags.contains(AllocatorPageFlags::NoOwner) {

                    for split_order in (order.clone().to_buddy_size()..current_order).rev() {
                        let sec_page = page.add(1 << split_order);
                        (*sec_page).order = split_order;
                        (*sec_page).flags.insert(AllocatorPageFlags::IsFree);
                        (*sec_page).magic = 0x4B334F53;
                        self.free_lists[split_order as usize].push_back(sec_page);
                    }
                    self.free_pages_count -= 1 << order.to_buddy_size();
                    (*page).flags.remove(AllocatorPageFlags::IsFree);
                    (*page).order = order.to_buddy_size();
                    return Some(get_addr_from_page(page, &*self.metadata_chunks));
                }
            }
        }
        None
    }

    unsafe fn dealloc(&mut self, addr: PhysAddr, size: AllocationSize) {
        // get the first block
        assert!((size as u8) >= _4KB as u8, "BuddyAllocator: attempted to deallocate a Slub-sized block!");
        let page = get_page(&*self.metadata_chunks, addr.as_u64());
        if (*page).owner_id != self.cpu_id {
            self.send_remote(page);
            return;
        }
        self.free_pages_count += 1 << size.to_buddy_size();
        self.internal_free(page);
        if self.free_pages_count > 5 * 1024 {
            self.collect_from_remote_list();
            let chunks_ptr = &*self.metadata_chunks;
            for order_list in self.free_lists.iter_mut().rev() {
                if self.free_pages_count <= 4096 { break; }
                let mut current = order_list.lookup_front();
                while !current.is_null() {
                    if self.free_pages_count <= 4096 { break; }

                    // Сохраняем "следующего", пока "текущий" еще жив
                    let next_node = unsafe { (*current).list_node.next };
                    let buddy = get_buddy(chunks_ptr, current);
                    // Если соседа нет (край памяти), или он занят другим ядром,
                    // или мы уже достигли максимума (4MB) — отдаем.
                    let should_return = buddy.is_null()
                        || unsafe { (*buddy).owner_id != self.cpu_id }
                        || unsafe { (*current).order == _4MB.to_buddy_size() };

                    if should_return {
                        unsafe {
                            order_list.remove(&mut *current);
                            Self::return_page(chunks_ptr, current);
                        }
                    }

                    current = next_node;
                }
            }
        }
    }
    unsafe fn add_region(&mut self, _: MemoryRegion) -> Result<(), &'static str> {
        unimplemented!()
    }
    fn new(cpu_id: u8) -> Self {
        let metadata_chunks = ALLOCATOR.lock().get_chunks_ptr();
        let mut s = Self {
            free_lists: [const {IntrusiveList::new()}; BUDDY_LEVELS],
            metadata_chunks,
            free_pages_count: 0,
            cpu_id,
            remote_free_list: AtomicPtr::new(null_mut()),
        };
        unsafe { s.refill(_4MB); }
        s
    }

    unsafe fn alloc_virtual(&mut self, size: AllocationSize) -> Option<VirtAddr> {
        let allocd = self.alloc(size);
        if allocd.is_none() { None } else { Some(VirtAddr::new(allocd.unwrap().as_u64() + PHYS_OFFSET)) }
    }

    unsafe fn dealloc_virtual(&mut self, ptr: VirtAddr, size: AllocationSize) {
        self.dealloc(PhysAddr::new(ptr.as_u64() - PHYS_OFFSET), size);
    }
}

unsafe impl Send for BuddyAllocator {}
unsafe impl Sync for BuddyAllocator {}

pub unsafe fn add_boot_regions(regions: &mut [Option<MemoryRegion>; 64]) {
    let mut alloc = ALLOCATOR.lock();
    let metadata_size = size_of::<Page>() * PAGES_PER_CHUNK;
    for region in &mut *regions {
        if let Some(reg) = region {
            if reg.start < BOOT_MAPPING_SIZE as u64 {
                if reg.end <= reg.start { panic!("Region without any space! WTH?") }
                if (reg.end - reg.start) > (metadata_size * 2) as u64 {
                    let start = (reg.start + 4095) & !4095;
                    let page1 = (start + PHYS_OFFSET) as *mut Page;
                    write_bytes(page1, 0, PAGES_PER_CHUNK);
                    let page2 = (start + PHYS_OFFSET + metadata_size as u64) as *mut Page;
                    write_bytes(page2, 0, PAGES_PER_CHUNK);
                    for offset in 0..PAGES_PER_CHUNK {
                        let p1 = page1.add(offset);
                        let p2 = page2.add(offset);
                        (*p1).flags = AllocatorPageFlags::NoOwner;
                        (*p2).flags = AllocatorPageFlags::NoOwner;
                        (*p1).chunk = 0;
                        (*p2).chunk = 1;
                        (*p1).magic = 0x4B334F53;
                        (*p2).magic = 0x4B334F53;
                    }
                    alloc.chunks[0] = page1;
                    alloc.chunks[1] = page2;
                    *region = Some(MemoryRegion {
                        start: start + (metadata_size * 2) as u64,
                        end: reg.end,
                        kind: MemoryRegionKind::Usable,
                    });
                    break;
                }
            }
        }
    }
    for region in &mut *regions {
        if let Some(reg) = region {
            if reg.start < BOOT_MAPPING_SIZE as u64 {
                if reg.end <= reg.start { panic!("Region without any space! WTH?") }
                match alloc.add_region(MemoryRegion {
                    start: reg.start,
                    end: reg.end.min(BOOT_MAPPING_SIZE as u64),
                    kind: MemoryRegionKind::Usable,
                }) {
                    Ok(()) => {
                        if reg.end > BOOT_MAPPING_SIZE as u64 {
                            *region = Some(MemoryRegion {
                                start: BOOT_MAPPING_SIZE as u64,
                                end: reg.end,
                                kind: MemoryRegionKind::Usable,
                            });
                        } else {
                            *region = None;
                        }
                    }
                    Err(msg) => {
                        println!("{}", &msg)
                    }
                };
            }
        }
    }
}
pub unsafe fn _add_other_regions(regions: &mut [Option<MemoryRegion>; 64]) {
    let mut alloc = ALLOCATOR.lock();
    let mut needed_chunks = [false; MAX_CHUNKS];
    for region in &mut *regions {
        if let Some(region) = region {
            if region.end <= region.start { panic!("Region without any space! WTH?") }
            let st_chunk = region.start / (4096 * PAGES_PER_CHUNK as u64);
            let end_chunk = (region.end - 1) / (4096 * PAGES_PER_CHUNK as u64);
            for chunk in st_chunk..=end_chunk {
                needed_chunks[chunk as usize] = true;
            }
        }
    }
    let metadata_size = size_of::<Page>() * PAGES_PER_CHUNK;
    for (chunk_idx, need_chunk) in needed_chunks.iter_mut().enumerate() {
        if !*need_chunk { continue; }
        for region in &mut regions.iter_mut().flatten() {
            if region.end - region.start >= metadata_size as u64 {
                let virt_addr = (region.start + PHYS_OFFSET) as *mut Page;

                // Инициализируем
                write_bytes(virt_addr, 0, PAGES_PER_CHUNK);
                for offset in 1..PAGES_PER_CHUNK {
                    let page = virt_addr.add(offset);
                    (*page).chunk = chunk_idx as u16;
                    (*page).magic = 0x4B334F53;
                    (*page).flags = AllocatorPageFlags::NoOwner;
                }
                alloc.chunks[chunk_idx] = virt_addr;
                (*virt_addr).flags = AllocatorPageFlags::NoOwner | AllocatorPageFlags::IsFree;
                (*virt_addr).chunk = chunk_idx as u16;
                (*virt_addr).magic = 0x4B334F53;
                // "Откусываем"
                region.start += metadata_size as u64;
                *need_chunk = false; // Потребность закрыта
                break; // Переходим к следующему chunk_idx
            }
        }
    };
    if needed_chunks.contains(&true) { panic!("Chunk metadata not initialized! WHERE THE FUCK IS ALL THE PLACE????"); }
    for region in &mut regions.iter_mut().flatten() {
        match alloc.add_region(*region) {
            Ok(()) => {}
            Err(msg) => println!("{}", &msg)
        }
    }
}
