
use shared::Out;
use crate::arch::CurrentOut;

pub struct KernelWriter;

impl core::fmt::Write for KernelWriter {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        CurrentOut::serial_print(s);
        Ok(())
    }
}
/// Prints the string and it's arguments to the serial (for now)
#[macro_export]
macro_rules! print {
    ($($arg:tt)*) => {{
        use core::fmt::Write;
        // Создаем локальную мутабельную переменную для записи
        let mut writer = $crate::utils::KernelWriter;
        let _ = write!(writer, $($arg)*);
    }};
}
/// Prints the string and it's arguments to the serial (for now) with a new line
#[macro_export]
macro_rules! println {
    () => ($crate::print!("\n"));
    ($($arg:tt)*) => ($crate::print!("{}\n", format_args!($($arg)*)));
}