ENTRY(_start)

SECTIONS {
    /* Физический адрес загрузки — 1 МБ */
    . = 1M;
    PROVIDE(__phys_base = .);

    /* Секция загрузки — должна быть в начале файла */
    .boot 1M : {
        KEEP(*(.multiboot_header))
        *(.boot)
    }

    /* Прыгаем по VMA (виртуально), но физически продолжаем с того же места */
    . = . + 0xFFFF800000000000;
    .text : AT(ADDR(.text) - 0xFFFF800000000000) {
        *(.text .text.* .ltext .ltext.*)  /* Добавили .ltext */
    }

    .rodata : AT(ADDR(.rodata) - 0xFFFF800000000000) {
        *(.rodata .rodata.* .lrodata .lrodata.*)
    }

    .data : AT(ADDR(.data) - 0xFFFF800000000000) {
        *(.data .data.* .ldata .ldata.*)
    }


    .bss : AT(ADDR(.bss) - 0xFFFF800000000000) {
        *(COMMON)
        *(.bss .bss.* .lbss .lbss.*)
    }
    . = ALIGN(4K);
    PROVIDE(__phys_end = . - 0xFFFF800000000000);
}
