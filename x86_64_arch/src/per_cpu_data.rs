use core::arch::asm;
use shared::multicore::{ArchSpecific, CpuLocalAllocator, PerCpuData};

#[derive(Default)]
pub struct X86ArchSpecific {
    interrupt_stack: u64
}


impl ArchSpecific for X86ArchSpecific {
    fn get_interrupt_stack(&self) -> u64 { self.interrupt_stack }

    unsafe fn install_per_cpu<A, B>(addr: *const PerCpuData<A, B, Self>)
    where A: CpuLocalAllocator,
        B: CpuLocalAllocator {
        let addr = addr as u64;
        let low = (addr & 0xFFFF_FFFF) as u32;
        let high = (addr >> 32) as u32;
        asm!(
        "wrmsr",
        in("ecx") 0xC0000101u32,
        in("eax") low,
        in("edx") high,
        options(nostack, preserves_flags)
        );
    }

    unsafe fn get_per_cpu<A, B>() -> *mut PerCpuData<A, B, Self>
    where A: CpuLocalAllocator,
          B: CpuLocalAllocator {
        let ptr: *mut PerCpuData<A, B, Self>;
        asm!(
        "mov {0}, gs:[0]",
        out(reg) ptr,
        options(pure, readonly, nostack, preserves_flags)
        );
        ptr
    }
}