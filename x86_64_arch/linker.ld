ENTRY(_start)

SECTIONS {
    . = 1M;

    __kernel_start = .;

    .boot : {
        KEEP(*(.multiboot_header))
    }

    .text : {
        *(.text .text.*)
    }

    .rodata : {
        *(.rodata .rodata.*)
    }

    .data : {
        *(.data .data.*)
    }

    .bss : {
        *(COMMON)
        *(.bss .bss.*)
    }

    /* Правильный синтаксис выравнивания текущего адреса */
    . = ALIGN(4K);
    __kernel_end = .;
}