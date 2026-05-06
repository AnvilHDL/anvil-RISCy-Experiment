    .equ LED_MMIO,      0x10000008
    .equ UART_THR_MMIO, 0x10000000
    # 25 MHz / 115200 baud = 217 clocks/bit, 10 bits/char = 2170 clocks/char
    # We wait 2500 clocks between characters (safe margin), and 25,000,000
    # clocks (1 second) between banner repeats.
    .equ CLKS_PER_CHAR, 2500
    .equ CLKS_PER_SEC,  25000000

    .section .text._start
    .globl _start
_start:
    # Write 0x5A to LED register to show we reached here (LED[3,5,6] ON)
    li   t0, LED_MMIO
    li   t1, 0x5a
    sb   t1, 0(t0)

    li   t3, UART_THR_MMIO

    # Print banner once per second, forever. This intentionally uses no stack
    # or BRAM data loads; the first UART store occurs before the first call.
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

    # 1-second delay (approx — putstr time is tiny compared to 1s)
    li   t5, CLKS_PER_SEC
delay_1s:
    addi t5, t5, -1
    bnez t5, delay_1s

    j    banner_loop

char_delay:
    li   t5, CLKS_PER_CHAR
char_wait:
    addi t5, t5, -1
    bnez t5, char_wait
    ret
