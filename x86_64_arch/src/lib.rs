#![no_std]

pub mod multiboot;
pub mod per_cpu_data;
pub mod paging;

use core::arch::asm;
use shared::Out;

pub struct Port {
    port: u16
}

impl Port {
    pub fn new(port: u16) -> Self { Self { port } }
    pub unsafe fn write(&self, value: u8) {
        asm!("out dx, al", in("dx") self.port, in("al") value, options(nomem, nostack, preserves_flags));
    }
    pub unsafe fn read(&self) -> u8 {
        let res: u8;
        asm!("in al, dx", out("al") res, in("dx") self.port, options(nomem, nostack, preserves_flags));
        res
    }
}


pub struct X86Out {}

impl Out for X86Out {
    fn serial_println(text: &str) {
        X86Out::serial_print(text);
        unsafe {
            X86Out::serial_putc(b'\r');
            X86Out::serial_putc(b'\n');
        }
    }

    fn serial_println_hex(value: u64) {
        X86Out::serial_print_hex(value);
        unsafe {
            X86Out::serial_putc(b'\r');
            X86Out::serial_putc(b'\n');
        }
    }
    // Вывод одного символа (базовая единица)
    unsafe fn serial_putc(c: u8) {
        let in_port = Port::new(0x3fd);
        let out_port = Port::new(0x3f8);
        // Ждем готовности передатчика (бит 5 порта Line Status)
        while in_port.read() & 0x20 == 0 {}
        out_port.write(c);
    }

    // Печать строки без перевода строки
    fn serial_print(text: &str) {
        for byte in text.bytes() {
            unsafe { X86Out::serial_putc(byte); }
        }
    }
    // Печать числа u64 в Hex (0xABC...)
    fn serial_print_hex(mut value: u64) {
        X86Out::serial_print("0x");
        if value == 0 {
            unsafe { X86Out::serial_putc(b'0'); }
            return;
        }

        // Печатаем с конца или используем буфер
        let mut buffer = [0u8; 16];
        for i in (0..16).rev() {
            let nibble = (value & 0xF) as u8;
            buffer[i] = if nibble < 10 { b'0' + nibble } else { b'A' + (nibble - 10) };
            value >>= 4;
        }

        // Пропускаем ведущие нули для красоты
        let mut started = false;
        for &byte in &buffer {
            if byte != b'0' || started {
                unsafe { X86Out::serial_putc(byte); }
                started = true;
            }
        }
    }
    fn serial_print_bool(text: bool) {
        unsafe { X86Out::serial_putc(if text == true {b'1'} else { b'0' }); }
    }

    fn serial_println_bool(text: bool) {
        unsafe {
            X86Out::serial_putc(if text == true {b'1'} else { b'0' });
            X86Out::serial_putc(b'\r');
            X86Out::serial_putc(b'\n');
        }
    }
}