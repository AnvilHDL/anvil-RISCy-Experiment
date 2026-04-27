    .section .text._start
    .globl _start
_start:
    la sp, __stack_top
    call main
    li a7, 93
    ecall
1:
    j 1b
