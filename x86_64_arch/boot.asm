section .multiboot_header
align 8
header_start:
    dd 0xe85250d6                ; Magic number (multiboot 2)
    dd 0                         ; Architecture 0 (protected mode i386)
    dd header_end - header_start ; Header length
    dd 0x100000000 - (0xe85250d6 + 0 + (header_end - header_start)) ; Checksum
    ; Конец тегов
    dw 0
    dw 0
    dd 8
header_end:

section .text
bits 32
global _start
extern _start_kernel

_start:
    mov esp, stack_top
    mov edi, ebx       ; Сохраняем указатель на Multiboot структуру в edi (по соглашению x86_64)

    ; 1. Настройка таблиц страниц
    mov eax, pdpt_table
    or eax, 0b11
    mov [pml4_table], eax

    mov eax, pd_table
    or eax, 0b11
    mov [pdpt_table], eax

    ; --- ЦИКЛ МАППИНГА 1 Гб ---
    mov ecx, 0         ; Счетчик записей (0..511)
.map_pd_table:
    mov eax, 0x200000  ; Размер одной страницы (2 МиБ)
    mul ecx            ; EAX = 2Мб * ECX
    or eax, 0b10000011 ; Present + Writable + Huge
    mov [pd_table + ecx * 8], eax

    inc ecx
    cmp ecx, 512
    jne .map_pd_table
    ; --------------------------

    ; 2. Включаем PAE
    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    ; 3. Включаем Long Mode (EFER.LME)
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr

    mov eax, cr0
    and ax, 0xFFFB      ; Сбросить CR0.EM (Bit 2), установить CR0.MP (Bit 1)
    or ax, 0x2
    mov cr0, eax
    mov eax, cr4
    or eax, 3 << 9      ; Установить CR4.OSFXSR (Bit 9) и CR4.OSXMMEXCPT (Bit 10)
    mov cr4, eax

    ; 4. Включаем Paging
    mov eax, pml4_table
    mov cr3, eax

    mov eax, cr0
    or eax, 1 << 31
    mov cr0, eax

    ; 5. Прыжок в 64-битный код
    lgdt [gdt64.pointer]
    ; Важно: в Rust _start_kernel придет в RDI указатель на Multiboot
    jmp gdt64.code:long_mode_entry

bits 64
long_mode_entry:
    ; Обнуляем сегменты (для 64 бит это норма)
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    ; Теперь прыгаем в Rust
    extern _start_kernel
    call _start_kernel

section .rodata
gdt64:
    dq 0 ; zero entry
.code equ $ - gdt64    ; ТЕПЕРЬ ПРАВИЛЬНО
    dq (1<<43) | (1<<44) | (1<<47) | (1<<53) ; code segment
.pointer:
    dw $ - gdt64 - 1
    dq gdt64

section .bss
align 4096
pml4_table: resb 4096
pdpt_table: resb 4096
pd_table:   resb 4096
stack_bottom:
    resb 4096 * 64
stack_top equ $