ENTRY(_start)

__stack_top = 0x801ffff8;

SECTIONS
{
    . = 0x80000000;

    .text : {
        KEEP(*(.text._start))
        *(.text .text.*)
        *(.rodata .rodata.*)
    }

    . = ALIGN(8);
    .data : {
        *(.data .data.*)
    }

    . = ALIGN(8);
    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }

    . = ALIGN(8);
    _end = .;
}
