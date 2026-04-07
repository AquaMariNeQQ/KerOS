use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap();
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out_dir = env::var("OUT_DIR").unwrap();
    let boot_s = format!("../{}_arch/boot.asm", arch); // Путь к твоему NASM файлу
    if !Path::new(&boot_s).exists() {
        panic!("Missing boot assembly for architecture: {}. Expected at: {}", arch, boot_s);
    }

    // Компилируем NASM (только для x86, для ARM понадобится другой компилятор, например clang/gcc)
    if arch == "x86_64" {
        let status = Command::new("nasm")
            .args(&["-f", "elf64", &boot_s, "-o"])
            .arg(format!("{}/boot.o", out_dir))
            .status()
            .expect("Failed to run NASM");

        if !status.success() { panic!("NASM failed"); }
        println!("cargo:rustc-link-arg={}/boot.o", out_dir);
    }
    // Выходим из /kernel в корень проекта, чтобы попасть в /x86_64_arch
    let linker_script = manifest_dir
        .parent()
        .unwrap()
        .join(format!("{}_arch", arch))
        .join("linker.ld");

    if !linker_script.exists() {
        panic!("Linker script not found at: {}", linker_script.display());
    }

    // Сообщаем Cargo, что нужно пересобраться, если скрипт изменился
    println!("cargo:rerun-if-changed={}", linker_script.display());

    // ПЕРЕДАЕМ ПУТЬ ЛИНКЕРУ
    println!("cargo:rustc-link-arg=-T{}", linker_script.display());

    // Остальная твоя магия (nasm, stubs и т.д.)
}