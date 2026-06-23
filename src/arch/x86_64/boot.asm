%define K_VIRT_BASE 0xFFFF800000000000

section .multiboot_header
align 8
header_start:
    dd 0xe85250d6
    dd 0
    dd header_end - header_start
    dd 0x100000000 - (0xe85250d6 + 0 + (header_end - header_start))
    dw 0
    dw 0
    dd 8
header_end:

section .boot
bits 32
global boot_gdt
align 16
boot_gdt:
    dq 0 ; null descriptor
.code equ $ - boot_gdt
    dq 0x00af9a000000ffff ; Code: Executable, Readable
.data equ $ - boot_gdt
    dq 0x00cf92000000ffff ; Data: Writable, Readable
.tss equ $ - boot_gdt
    dq 0, 0

boot_gdt_end:
gdt_ptr:
    dw $ - boot_gdt - 1
    dd boot_gdt

global _start
extern _start_kernel

_start:
    mov esp, stack_top - K_VIRT_BASE
    mov edi, ebx

    mov eax, pdpt_table - K_VIRT_BASE
    or eax, 0b11
    mov [pml4_table - K_VIRT_BASE], eax          ; Identity mapping
    mov [pml4_table - K_VIRT_BASE + 2048], eax   ; Higher Half mapping (slot 256)

    mov eax, pd_table - K_VIRT_BASE
    or eax, 0b11
    mov [pdpt_table - K_VIRT_BASE], eax
    mov [pdpt_table - K_VIRT_BASE + 0], eax

    mov ecx, 0

.map_pd_table:
    mov eax, 0x200000
    mul ecx
    or eax, 0b10000011
    mov [pd_table - K_VIRT_BASE + ecx * 8], eax
    inc ecx
    cmp ecx, 512
    jne .map_pd_table

    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    mov ecx, 0xC0000080
    rdmsr
    or eax, (1 << 8) | (1 << 11)
    wrmsr

    mov eax, cr0
    and ax, 0xFFFB
    or ax, 0x2
    mov cr0, eax
    mov eax, cr4
    or eax, 3 << 9
    mov cr4, eax

    mov eax, pml4_table - K_VIRT_BASE
    mov cr3, eax
    mov eax, cr0
    or eax, 1 << 31
    mov cr0, eax

    lgdt [gdt_ptr]

    push dword boot_gdt.code
    mov eax, long_mode_entry
    push eax

    retf
bits 64
long_mode_entry:
    mov rax, .upper_jump
    jmp rax

.upper_jump:
    mov rsp, stack_top
    and rsp, -16

    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    movabs rax, gdt_ptr_high
    push 0x08 ; code selector
    lea rax, [.reload_cs]
    push rax
    retfq

.reload_cs:
    mov rax, _start_kernel
    call rax
section .rodata
align 16
global gdt_ptr_high
gdt_ptr_high:
    dw boot_gdt_end - boot_gdt - 1
    dq (boot_gdt + K_VIRT_BASE)
section .bss
align 4096
pml4_table: resb 4096
pdpt_table: resb 4096
pd_table:   resb 4096
stack_bottom:
    resb 4096 * 64
stack_top: