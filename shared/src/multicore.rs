use bitflags::bitflags;
use crate::lists::intrusive_linked_list::{IntrusiveNode, IntrusiveNodeAccess};
use crate::sched::SchedulerQueue;
use crate::{MemoryRegion, PhysAddr, VirtAddr};
use crate::multicore::AllocationSize::_4KB;

pub trait CpuLocalAllocator {
    unsafe fn alloc(&mut self, size: AllocationSize) -> Option<PhysAddr>;
    unsafe fn dealloc(&mut self, addr: PhysAddr, size: AllocationSize);
    unsafe fn add_region(&mut self, region: MemoryRegion) -> Result<(), &'static str>;
    fn new(cpu_id: u8) -> Self;
    // Возвращает виртуальный адрес (уже с учетом PHYS_OFFSET)
    unsafe fn alloc_virtual(&mut self, size: AllocationSize) -> Option<VirtAddr>;

    // Принимает виртуальный адрес, сам вычитает смещение и отдает фрейм в Buddy/Slub
    unsafe fn dealloc_virtual(&mut self, ptr: VirtAddr, size: AllocationSize);
}
#[repr(C, align(32))]
pub struct Page {
    // Узел для IntrusiveList (Buddy free_lists, Slub partial_list)
    /// List for buddy, sometimes - for other things.
    pub list_node: IntrusiveNode<Page>,

    // Состояние страницы
    /// Normally - 0x4B334F53
    pub magic: u32,          // Твой 0x4B334F53
    /// Flags for allocator ONLY
    pub flags: AllocatorPageFlags,          // Битовое поле: [0: IsFree, 1: IsSlab, 2: IsActive...]
    /// 1 << order + 12 = size in bytes
    pub order: u8,           // Текущий порядок в Buddy (0..10)
    /// CPU ID; If isn't owned by CPU - most likely 0x00, but you should look for flag NoOwner in flags
    pub owner_id: u8,        // ID CPU (0xFF для глобального Buddy)
    /// How many objects are right now on this page. Nothing about the size and max amount of objects on this page will be provided here
    pub usage: u16,          // Кол-во занятых объектов (для Slub)
    /// Which chunk (out of 4096 max) it is in
    pub chunk: u16,
    // Slub-специфичные данные
    /// Free list for SLUB
    pub free_list_head: u64, // Физический/Виртуальный адрес первого свободного объекта

}

bitflags! {
    pub struct AllocatorPageFlags: u32 {
        const IsFree = 1 << 0;
        const NoOwner = 1 << 1;
    }
}

#[repr(C)]
pub struct PerCpuData<A, B, T>
where A: CpuLocalAllocator, B: CpuLocalAllocator, T: ArchSpecific
{
    pub self_pointer: *const Self,
    pub cpu_id: u8,
    pub current_stack_ptr: u64,
    pub preemption_count: u16,
    pub run_queue: Option<SchedulerQueue>,
    pub local_buddy: A,
    pub local_slub: B,
    pub arch_data: T
}

impl IntrusiveNodeAccess for Page {
    fn get_node(&self) -> *const IntrusiveNode<Self> {
        &self.list_node
    }
    fn get_node_mut(&mut self) -> *mut IntrusiveNode<Self> {
        &mut self.list_node
    }
}

#[repr(u8)]
#[derive(Copy, Clone, Eq, PartialEq, Debug)]
pub enum AllocationSize {
    _8B = 0,
    _16B = 1,
    _32B = 2,
    _64B = 3,
    _128B = 4,
    _256B = 5,
    _512B = 6,
    _1KB = 7,
    _2KB = 8,
    _4KB = 9,
    _8KB = 10,
    _16KB = 11,
    _32KB = 12,
    _64KB = 13,
    _128KB = 14,
    _256KB = 15,
    _512KB = 16,
    _1MB = 17,
    _2MB = 18,
    _4MB = 19,
}

impl AllocationSize {
    pub fn from_size(size: usize, align: usize) -> Self {
        let required = size.max(align).max(8); // Минимум 8 байт и учет выравнивания
        let bit = required.next_power_of_two().trailing_zeros() as u8;
        let index = bit.saturating_sub(3);
        unsafe { core::mem::transmute(index.min(19)) }
    }
    pub fn to_buddy_size(&self) -> u8 {
        assert!(*self as u8 >= _4KB as u8, "Trying to get a size for buddy allocator from AllocationSize, got something below 4KB");
        ((*self) as u8) - 9
    }
    pub fn from_buddy_order(order: u8) -> Self {
        unsafe { core::mem::transmute(order + 9) }
    }
    pub fn get_size(&self) -> usize {
        match self {
            Self::_8B => 8,
            Self::_16B => 16,
            Self::_32B => 32,
            Self::_64B => 64,
            Self::_128B => 128,
            Self::_256B => 256,
            Self::_512B => 512,
            Self::_1KB => 1024,
            Self::_2KB => 2048,
            Self::_4KB => 4096,
            Self::_8KB => 8192,
            Self::_16KB => 16384,
            Self::_32KB => 32768,
            Self::_64KB => 65536,
            Self::_128KB => 131072,
            Self::_256KB => 262144,
            Self::_512KB => 524288,
            Self::_1MB => 1048576,
            Self::_2MB => 2097152,
            Self::_4MB => 4194304,
        }
    }
}

pub trait ArchSpecific: Default {
    fn get_interrupt_stack(&self) -> u64;
    unsafe fn install_per_cpu<A, B>(addr: *const PerCpuData<A, B, Self>)
    where A: CpuLocalAllocator,
          B: CpuLocalAllocator;
    unsafe fn get_per_cpu<A, B>() -> *mut PerCpuData<A, B, Self>
    where A: CpuLocalAllocator,
          B: CpuLocalAllocator;
}