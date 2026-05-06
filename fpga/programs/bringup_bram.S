    .equ LED_MMIO,      0x30000000
    .equ UART_THR_MMIO, 0x10000000
    .equ UART_LSR_MMIO, 0x10000005
    .equ UART_THRE,     0x20

    .section .text._start
    .globl _start
_start:
    la   sp, __stack_top

    li   t0, LED_MMIO
    li   t1, 0x5a
    sb   t1, 0(t0)

    la   a0, msg_boot
    call putstr
    la   a0, msg_b
    call putstr
    la   a0, msg_led
    call putstr

1:
    j    1b

putstr:
    lbu  t2, 0(a0)
    beqz t2, 3f
2:
    li   t3, UART_LSR_MMIO
    lbu  t4, 0(t3)
    andi t4, t4, UART_THRE
    beqz t4, 2b
    li   t3, UART_THR_MMIO
    sb   t2, 0(t3)
    addi a0, a0, 1
    j    putstr
3:
    ret

    .section .rodata
msg_boot:
    .asciz "BOOT\r\n"
msg_b:
    .asciz "B\r\n"
msg_led:
    .asciz "L=5A\r\n"
