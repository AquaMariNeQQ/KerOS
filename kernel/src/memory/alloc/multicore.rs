use core::ptr::null_mut;
use shared::multicore::AllocationSize::_4KB;
pub use crate::arch::CurrentData;
pub use crate::arch::CurrentOut;
use crate::memory::alloc::buddy::CpuLocalBuddyAllocator;
use crate::memory::alloc::slub::SlubAllocator;
use shared::multicore::{ArchSpecific, CpuLocalAllocator};
use shared::multicore::PerCpuData;
use shared::{FrameAllocator, Out};
use crate::memory::alloc::{ALLOCATOR, PHYS_OFFSET};

pub trait CpuContext {
    fn new(cpu_id: u8) -> &'static mut Self;
}
impl CpuContext for PerCpuData<CpuLocalBuddyAllocator, SlubAllocator, CurrentData> {
    fn new(cpu_id: u8) -> &'static mut Self {
        let phys;
        {
            let mut alloc = ALLOCATOR.lock();
            phys = unsafe { alloc.alloc(_4KB).unwrap() };
        }
        let virt = unsafe { phys.as_u64() + PHYS_OFFSET };
        let virt_ptr = virt as *mut Self;
        CurrentOut::serial_println("AA");
        let cpu_local_buddy = CpuLocalBuddyAllocator::new(cpu_id);
        CurrentOut::serial_println("AB");
        let cpu_local_slub = SlubAllocator::new(cpu_id);
        CurrentOut::serial_println("AC");
        let data = Self {
                self_pointer: virt_ptr,
                cpu_id,
                current_stack_ptr: 0u64,
                preemption_count: 0,
                run_queue: None,
                local_buddy: cpu_local_buddy,
                local_slub: cpu_local_slub,
                arch_data: CurrentData::default()
        };
        CurrentOut::serial_println("BB");
        unsafe {
            virt_ptr.write(data);
            CPU_DATA[cpu_id as usize] = virt_ptr;
            &mut *virt_ptr
        }
    }
}

pub static mut CPU_DATA: [*mut PerCpuData<CpuLocalBuddyAllocator, SlubAllocator, CurrentData>; 256] = [null_mut(); 256];

pub fn create_per_cpu(id: u8) {
    let data = PerCpuData::new(id);
    unsafe { CurrentData::install_per_cpu(data); }
}