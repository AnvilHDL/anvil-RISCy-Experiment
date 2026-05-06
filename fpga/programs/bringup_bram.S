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
    la   sp, __stack_top

    # Write 0x5A to LED register to show we reached here (LED[3,5,6] ON)
    li   t0, LED_MMIO
    li   t1, 0x5a
    sb   t1, 0(t0)

    # Print banner once per second, forever. No MMIO reads — pure stores.
banner_loop:
    la   a0, msg_banner
    call putstr_timed

    # 1-second delay (approx — putstr time is tiny compared to 1s)
    li   t5, CLKS_PER_SEC
delay_1s:
    addi t5, t5, -1
    bnez t5, delay_1s

    j    banner_loop

# putstr_timed: print null-terminated string using cycle-count delay.
# No MMIO reads, no LSR polling. Just write each byte and wait 2500 cycles.
# a0 = string pointer (preserved across call via stack)
putstr_timed:
    addi sp, sp, -16
    sd   ra, 8(sp)
    sd   s0, 0(sp)
    mv   s0, a0
char_loop:
    lbu  t2, 0(s0)
    beqz t2, char_done
    # Write byte to UART THR (unconditional)
    li   t3, UART_THR_MMIO
    sb   t2, 0(t3)
    # Wait for UART to finish this character (2500 cycles)
    li   t5, CLKS_PER_CHAR
char_wait:
    addi t5, t5, -1
    bnez t5, char_wait
    addi s0, s0, 1
    j    char_loop
char_done:
    ld   ra, 8(sp)
    ld   s0, 0(sp)
    addi sp, sp, 16
    ret

    .section .rodata
msg_banner:
    .asciz "RISCy ALIVE! BOOT OK LED=5A\r\n"
