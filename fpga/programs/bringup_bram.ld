ENTRY(_start)

MEMORY
{
    bram (rwx) : ORIGIN = 0x80000000, LENGTH = 4K
}

__stack_top = ORIGIN(bram) + LENGTH(bram) - 8;

SECTIONS
{
    . = ORIGIN(bram);

    .text : {
        KEEP(*(.text._start))
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > bram

    . = ALIGN(8);
    .data : {
        *(.data .data.*)
    } > bram

    . = ALIGN(8);
    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } > bram

    . = ALIGN(8);
    _end = .;
}
