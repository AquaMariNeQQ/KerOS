#!/bin/bash
set -e
source "$HOME/.cargo/env"
echo -e "\e[35m--- Phase 1: Build ---\e[0m"

# Собираем ядро
# Мы используем встроенную переменную, чтобы Cargo сам подхватил таргет
cargo build -p kernel --target x86_64-elf.json \
    -Z build-std=core,compiler_builtins,alloc \
    -Z build-std-features=compiler-builtins-mem \
    -Zjson-target-spec

echo -e "\e[36m--- Phase 2: Building ISO ---\e[0m"

ISO_DIR="isofiles"
rm -rf $ISO_DIR
mkdir -p $ISO_DIR/boot/grub

# Копируем бинарник (путь в Linux короче и без обратных слешей)
cp target/x86_64-elf/debug/keros $ISO_DIR/boot/keros

# Генерируем grub.cfg
cat << EOF > $ISO_DIR/boot/grub/grub.cfg
set timeout=0
set default=0
insmod all_video
menuentry "KerOS" {
    multiboot2 /boot/keros
    boot
}
EOF

# Собираем ISO напрямую (никакого WSL!)
grub-mkrescue -o keros.iso $ISO_DIR

echo -e "\e[32m--- Phase 3: Launching QEMU ---\e[0m"

# В Linux QEMU работает быстрее с -enable-kvm, но для начала запустим просто
qemu-system-x86_64 \
    -m 2G \
    -drive format=raw,file=keros.iso,index=0,media=cdrom \
    -serial stdio \
    -display sdl \
    -vga std \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -d cpu_reset,int,guest_errors \
    -D /tmp/qemu.log \
#    -s -S

#qemu-system-x86_64 \
#    -m 2G \
#    -drive format=raw,file=keros.iso,index=0,media=cdrom \
#    -serial file:serial.log \
#    -display sdl \
#    -vga std \
#    -d cpu_reset,int,guest_errors \
#    -D /tmp/qemu.log \
#    -monitor stdio