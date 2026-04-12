ENTRY(_start)

__stack_top = 0x0000fff8;

SECTIONS
{
    . = 0x00000000;

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
