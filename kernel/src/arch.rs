#![cfg(target_arch = "x86_64")]

pub type CurrentBootSource = x86_64_arch::multiboot::Multiboot2Source;
pub type CurrentOut = x86_64_arch::X86Out;
pub type CurrentData = x86_64_arch::per_cpu_data::X86ArchSpecific;
pub type CurrentPaging = x86_64_arch::paging::X86Paging;
