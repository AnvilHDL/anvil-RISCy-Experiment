    .equ LED_MMIO,      0x10000008
    .equ UART_THR_MMIO, 0x10000000
    # 25 MHz / 115200 baud = 217 clocks/bit, 10 bits/char = 2170 clocks/char
    # We wait 2500 loop iterations between characters and use a shorter banner
    # delay because the core takes multiple cycles per loop instruction.
    .equ CLKS_PER_CHAR, 2500
    .equ BANNER_DELAY,  5000000

    .section .text._start
    .globl _start
_start:
    # Write 0x5A to LED register to show we reached here (LED[3,5,6] ON)
    li   t0, LED_MMIO
    li   t1, 0x5a
    sb   t1, 0(t0)

    li   t3, UART_THR_MMIO

    # Print banner repeatedly from BRAM data memory. This is the correctness
    # gate for load-address timing before moving on to DDR/xv6.
banner_loop:
    la   t4, msg_banner
char_loop:
    lbu  t2, 0(t4)
    beqz t2, banner_done
    sb   t2, 0(t3)
    call char_delay
    addi t4, t4, 1
    j    char_loop

banner_done:
    li   t5, BANNER_DELAY
banner_wait:
    addi t5, t5, -1
    bnez t5, banner_wait

    j    banner_loop

char_delay:
    li   t5, CLKS_PER_CHAR
char_wait:
    addi t5, t5, -1
    bnez t5, char_wait
    ret

    .section .rodata
msg_banner:
    .asciz "RISCy ALIVE!\r\n"
