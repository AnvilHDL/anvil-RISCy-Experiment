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

    # Print banner repeatedly using immediate bytes. Keep UART bringup on the
    # proven path; BRAM data-load debugging should not block the serial gate.
banner_loop:
    li   t2, 'R'
    sb   t2, 0(t3)
    call char_delay
    li   t2, 'I'
    sb   t2, 0(t3)
    call char_delay
    li   t2, 'S'
    sb   t2, 0(t3)
    call char_delay
    li   t2, 'C'
    sb   t2, 0(t3)
    call char_delay
    li   t2, 'y'
    sb   t2, 0(t3)
    call char_delay
    li   t2, ' '
    sb   t2, 0(t3)
    call char_delay
    li   t2, 'A'
    sb   t2, 0(t3)
    call char_delay
    li   t2, 'L'
    sb   t2, 0(t3)
    call char_delay
    li   t2, 'I'
    sb   t2, 0(t3)
    call char_delay
    li   t2, 'V'
    sb   t2, 0(t3)
    call char_delay
    li   t2, 'E'
    sb   t2, 0(t3)
    call char_delay
    li   t2, '!'
    sb   t2, 0(t3)
    call char_delay
    li   t2, '\r'
    sb   t2, 0(t3)
    call char_delay
    li   t2, '\n'
    sb   t2, 0(t3)
    call char_delay

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
