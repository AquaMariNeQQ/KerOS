#![feature(atomic_ptr_null)]
#![deny(warnings)]
#![warn(missing_docs)]
#![no_std]
#![no_main]

//! KerOS Kernel Core
//!
//! Это главный модуль ядра, отвечающий за инициализацию памяти,
//! настройку контекста процессоров и запуск основных систем.

extern crate alloc;
pub extern crate x86_64_arch;

mod utils;
mod memory;
mod arch;

use crate::arch::{CurrentBootSource, CurrentData, CurrentPaging};
use crate::memory::alloc::buddy::{add_boot_regions, CpuLocalBuddyAllocator};
use crate::memory::alloc::multicore::create_per_cpu;
use crate::memory::alloc::slub::SlubAllocator;
use core::arch::asm;
use core::panic::PanicInfo;
use shared::{BootSource, VirtAddr};
use shared::lists::adaptive_radix_tree::{ARTNodeHeader, ARTNodeType, ARTPointer, AdaptiveRadixTree, TreeError};
use shared::multicore::ArchSpecific;
use shared::memory::paging::{ArchConfig, MappingFlags};
use shared::PhysAddr;

use shared::memory::virtual_memory::{VMMRadixTree, VirtualRegion};

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    println!("\n!!! KERNEL PANIC !!!\n");
    if let Some(msg) = info.message().as_str() {
        println!("{}", msg);
    }
    if let Some(location) = info.location() {
        // Используй свой метод печати (serial или VGA)
        println!("Panic in {} at line {}", location.file(), location.line());
    }
    unsafe { print_stack_trace() }
    // Если в info есть сообщение, можно попытаться вывести и его
    unsafe {
        asm!("out dx, al", in("dx") 0xf4, in("al") 0x00u8);
    }
    loop {}
}

/// KerOS Kernel main start function
#[no_mangle]
pub extern "C" fn _start_kernel(boot_info_ptr: PhysAddr) -> ! {
    let mut boot_info = CurrentBootSource::parse(boot_info_ptr);
    unsafe { add_boot_regions(&mut boot_info.regions); }
    create_per_cpu(0);
    println!("We have {}mb of ram", boot_info.total_memory_bytes / (1024 * 1024));
    println!("KerOS ART Stress Test (1000 regions)...");
    let percpu = unsafe { CurrentData::get_per_cpu::<CpuLocalBuddyAllocator, SlubAllocator>() };
    let mut tree: VMMRadixTree<CurrentPaging> = AdaptiveRadixTree::<VirtAddr, VirtualRegion>::new();
    let count = 60000;
    let step = 32 * 1024 * 1024; // 2MB step
    let start_addr = 0x1_000_0000; // Начинаем с 1GB, чтобы не задеть kernel space
    for i in 0..count {
        let addr = start_addr + (i as u64 * step);
        let region = VirtualRegion {
            start: VirtAddr::new(addr),
            end: VirtAddr::new(addr + 0x1000), // Размер в 1 страницу
            flags: MappingFlags::empty(),
        };

        unsafe {
            match tree.insert(region.start, region, &mut (*percpu).local_slub) {
                Ok(_) => {}
                Err(e) => { match e {
                    TreeError::Overlap => {println!("Overlap, iteration {i}");panic!()}
                    TreeError::NotFound => {println!("Not found");panic!()}
                    TreeError::OutOfMemory => {println!("Out of memory");panic!()}
                    TreeError::InvalidRange => {println!("Invalid range");panic!()}
                    TreeError::StorageFull => {println!("StorageFull");panic!()}
                    TreeError::Contention => {println!("Contention"); panic!()}
                } }
            }
        }

        if i % 10000 == 0 {
            println!("Inserted {} regions...", i);
        }
    }
    println!("END");

    // println!("Insertion complete. Starting verification...");
    //
    // for i in 0..count {
    //     let addr = VirtAddr::new(start_addr + (i as u64 * step));
    //     unsafe {
    //         match tree.get(addr) {
    //             Some(reg) => {
    //                 if reg.start != addr {
    //                     panic!("Data corruption at index {}! Expected {:x}, got {:x}", i, addr.as_u64(), reg.start.as_u64());
    //                 }
    //             }
    //             None => panic!("Region at index {} ({:x}) disappeared!", i, addr.as_u64()),
    //         }
    //     }
    //     if i % 100000 == 0 {
    //         println!("Checked {} regions...", i);
    //     }
    // }
    //
    // println!("Verification SUCCESS! {count} regions handled.");
    // println!("ABOBA");
    // println!("Starting REMOVE & COLLAPSE Stress Test...");
    //
    // for i in (0..count).step_by(2) {
    //     let addr = VirtAddr::new(start_addr + (i as u64 * step));
    //     unsafe {
    //         match tree.remove(addr, &mut (*percpu).local_slub) {
    //             Ok(reg) => {
    //                 if reg.start != addr {
    //                     panic!("Remove returned wrong region at index {}!", i);
    //                 }
    //             }
    //             Err(e) => { println!("Failed to remove existing region at index {} (0x{:x}), e: {:?}", i, addr.as_u64(), e); panic!() },
    //         }
    //     }
    // }
    // println!("Partial remove (step 2) SUCCESS.");
    //
    // for i in 0..count {
    //     let addr = VirtAddr::new(start_addr + (i as u64 * step));
    //     unsafe {
    //         let found = tree.get(addr);
    //         if i % 2 == 0 {
    //             if found.is_some() { panic!("Region {} should be deleted, but still exists!", i); }
    //         } else {
    //             if found.is_none() { panic!("Region {} should exist, but disappeared during remove!", i); }
    //         }
    //     }
    // }
    // println!("Verification after partial remove SUCCESS.");
    //
    // let base_addr = 0x7000_0000_0000;
    // let addr_a = VirtAddr::new(base_addr | 0x1000);
    // let addr_b = VirtAddr::new(base_addr | 0x2000);
    //
    // unsafe {
    //     println!("[REGION] Start: 0x{:02x}, End: 0x{:02x}", addr_a.as_u64(), addr_a.as_u64() + 0x1000);
    //     match tree.get(addr_a) {
    //         None => {}
    //         Some(_) => {panic!()}
    //     }
    //     match tree.insert(addr_a, VirtualRegion { start: addr_a, end: VirtAddr::new(addr_a.as_u64() + 0x1000), flags: MappingFlags::empty() }, &mut (*percpu).local_slub) {
    //         Ok(_) => {}
    //         Err(e) => {println!("{:?}", e); panic!()}
    //     };
    //     println!("I1 COMPLETE.");
    //     tree.insert(addr_b, VirtualRegion { start: addr_b, end: VirtAddr::new(addr_b.as_u64() + 0x1000), flags: MappingFlags::empty() }, &mut (*percpu).local_slub).unwrap();
    //     println!("I2 COMPLETE.");
    //
    //     tree.remove(addr_a, &mut (*percpu).local_slub).expect("Collapse test remove failed");
    //     println!("R1 COMPLETE.");
    //     tree.remove(addr_b, &mut (*percpu).local_slub).expect("Collapse test remove failed");
    //     println!("R2 COMPLETE.");
    //     println!("R2D COMPLETE.");
    //
    // }
    //
    // println!("--- FINAL CLEANUP TEST ---");
    //
    // for i in (1..count).step_by(2) {
    //     let addr = VirtAddr::new(start_addr + (i as u64 * step));
    //     unsafe { match tree.remove(addr, &mut (*percpu).local_slub) {
    //         Ok(o) => o,
    //         Err(e) => {println!("{:?}", e); panic!()}
    //     }; }
    // }
    // println!("DUMP 2 (or 3)");
    // println!("DUMP 2 (or 3) complete.");
    //
    // let base_addr = 0x7000_0000_0000;
    // let addr_a = VirtAddr::new(base_addr | 0x1000);
    // let addr_b = VirtAddr::new(base_addr | 0x2000);
    //
    // unsafe {
    //     match tree.insert(addr_a, VirtualRegion { start: addr_a, end: VirtAddr::new(addr_a.as_u64() + 0x1000), flags: MappingFlags::empty() }, &mut (*percpu).local_slub) {
    //         Ok(_) => {}
    //         Err(e) => {println!("{:?}", e); panic!()}
    //     };
    //     match tree.insert(addr_b, VirtualRegion { start: addr_b, end: VirtAddr::new(addr_b.as_u64() + 0x1000), flags: MappingFlags::empty() }, &mut (*percpu).local_slub) {
    //         Ok(_) => {}
    //         Err(e) => {println!("{:?}", e); panic!()}
    //     };
    //
    //     println!("Tree with only 2 nodes (A and B):");
    //
    //     tree.remove(addr_a, &mut (*percpu).local_slub).unwrap();
    //     println!("Tree after removing A (Should be collapsed):");
    //
    //     tree.remove(addr_b, &mut (*percpu).local_slub).unwrap();
    //     println!("Tree after removing everything:");
    // }
    //
    // if !tree.root.is_null() {
    //     panic!("Tree root is not null after final cleanup!");
    // }
    // println!("Full cleanup SUCCESS!");
    // println!("Remove & Collapse tests PASSED!");
    // println!("Running Advanced Overlap Tests...");
    // unsafe {
    //     let base = 0x9000_0000_0000;
    //     let main_start = VirtAddr::new(base + 0x5000);
    //     let main_end = VirtAddr::new(base + 0x8000);
    //
        // tree.insert(main_start, VirtualRegion {
        //     start: main_start,
        //     end: main_end,
        //     flags: MappingFlags::empty()
        // }, &mut (*percpu).local_slub).expect("Failed to insert base overlap region");
        //
        // let cases = [
        //     ("Exact match", base + 0x5000, base + 0x8000),
        //     ("Overlap tail", base + 0x7000, base + 0x9000),
        //     ("Overlap head", base + 0x4000, base + 0x6000),
        //     ("Full contain (inner)", base + 0x6000, base + 0x7000),
        //     ("Full wrap (outer)", base + 0x3000, base + 0x10000),
        // ];
        //
        // for (name, s, e) in cases {
        //     let start = VirtAddr::new(s);
        //     let end = VirtAddr::new(e);
        //     match tree.insert(start, VirtualRegion { start, end, flags: MappingFlags::empty() }, &mut (*percpu).local_slub) {
        //         Err(TreeError::Overlap) => println!("PASS: {} detected", name),
        //         Ok(_) => panic!("FAIL: {} NOT detected! Region: {:x}-{:x}", name, s, e),
        //         Err(e) => panic!("FAIL: {} returned unexpected error {:?}", name, e),
        //     }
        // }
        //
        // tree.remove(main_start, &mut (*percpu).local_slub).unwrap();
    // }
    // println!("Advanced Overlap Tests PASSED!");
    unsafe {
        asm!("out dx, al", in("dx") 0xf4, in("al") 0x00u8);
    }
    loop {}
}

unsafe fn print_stack_trace() {
    let mut rbp: *const usize;
    // Получаем значение регистра RBP текущей функции
    core::arch::asm!("mov {}, rbp", out(reg) rbp);

    println!("--- BACKTRACE ---");

    let mut frame_count = 0;
    while !rbp.is_null() && frame_count < 20 {
        // В стандартном x86_64 кадре:
        // [rbp + 0] -> указатель на предыдущий rbp
        // [rbp + 8] -> адрес возврата (RIP)
        let rip = *rbp.add(1);
        let prev_rbp = *rbp as *const usize;

        println!("  [{:02}]: 0x{:016x}", frame_count, rip);

        // Переходим к следующему кадру
        if prev_rbp <= rbp {
            // Защита от зацикливания или битого стека
            break;
        }
        rbp = prev_rbp;
        frame_count += 1;
    }
    println!("--- END ---");
}


/// Dumps the ART (adaptive radix tree content)
pub unsafe fn dump<E: ArchConfig>(s: &VMMRadixTree<E>) {
    println!("--- ART DUMP START ---");
    if s.root.is_null() {
        println!("Empty Tree");
    } else {
        dump_recursive(s, s.root, 0, 0);
    }
    println!("--- ART DUMP END ---");
}


unsafe fn dump_recursive<E: ArchConfig>(s: &VMMRadixTree<E>, node: ARTPointer<E>, depth: usize, byte_label: u8) {
    // Печатаем отступ для визуализации глубины
    for _ in 0..depth { print!("  "); }

    print!("[{:02x}] ", byte_label);

    match node.get_type() {
        ARTNodeType::Leaf => {
            let reg = &*node.get_addr::<VirtualRegion>();
            println!("LEAF: 0x{:x} - 0x{:x}", reg.start.as_u64(), reg.end.as_u64());
        }
        ARTNodeType::Node256 => {
            println!("Node256: count={}", node.get_count());

            for b in 0..=255 {
                // Используй метод find_child, если он универсальный,
                // или проверяй node_ptr.children[b] на null вручную
                if let Some(child) = node.find_child(b as u8) {
                    dump_recursive(s, child, depth + 1, b as u8);
                }
            }
        }
        _ => {
            let hdr = &*node.get_addr::<ARTNodeHeader>();
            print!("{:?}: prefix_len={}, prefix=[", node.get_type(), hdr.prefix_len);
            println!("], count={}", node.get_count());
            for i in 0..hdr.prefix_len as usize {
                print!("{:02x}{}", hdr.prefix[i], if i == (hdr.prefix_len as usize - 1) { "" } else { " " });
            }

            // Обходим детей в зависимости от типа ноды
            for b in 0..=255 {
                if let Some(child) = node.find_child(b as u8) {
                    dump_recursive(s, child, depth + 1, b as u8);
                }
            }
        }
    }
}