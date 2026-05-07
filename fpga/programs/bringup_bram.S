    .equ LED_MMIO,      0x10000008
    .equ UART_THR_MMIO, 0x10000000

    # Delay loop counts are instruction-loop counts, not exact clock cycles.
    .equ CLKS_PER_CHAR, 2500
    .equ BANNER_DELAY,  5000000

    .section .text._start
    .globl _start
_start:
    li   t0, LED_MMIO
    li   t3, UART_THR_MMIO
    la   sp, __stack_top

    # Stage 0: reset vector, constants, and stack pointer are live.
    li   t1, 0x02
    sb   t1, 0(t0)

    # Stage 1: 64-bit constant load from BRAM data view.
    la   t4, probe_word
    ld   t2, 0(t4)
    li   t1, 0x1122334455667788
    bne  t2, t1, fail_ld_const
    li   t1, 0x08
    sb   t1, 0(t0)

    # Stage 2: BRAM store/load roundtrip at a scratch location.
    la   t4, scratch_area
    li   t1, 0x8877665544332211
    sd   t1, 0(t4)
    ld   t2, 0(t4)
    bne  t2, t1, fail_sd_ld
    li   t1, 0x10
    sb   t1, 0(t0)

    # Stage 3: byte/half/word unsigned loads from known byte lanes.
    li   t1, 0x1122334455667788
    sd   t1, 8(t4)
    lbu  t2, 8(t4)
    li   t1, 0x88
    bne  t2, t1, fail_lbu
    lhu  t2, 8(t4)
    li   t1, 0x7788
    bne  t2, t1, fail_lhu
    lwu  t2, 8(t4)
    li   t1, 0x55667788
    bne  t2, t1, fail_lwu
    li   t1, 0x18
    sb   t1, 0(t0)

    # Stage 4: call/return and stack store/load inside the 4 KB BRAM window.
    li   a0, 0x5a
    call stack_call_probe
    li   t1, 0xa5
    bne  a0, t1, fail_call_stack
    li   t1, 0x1c
    sb   t1, 0(t0)

pass_loop:
    li   t1, 0x1e
    sb   t1, 0(t0)
    la   a0, msg_pass
    call putstr_timed
    call banner_delay
    j    pass_loop

stack_call_probe:
    addi sp, sp, -16
    sd   ra, 8(sp)
    sd   a0, 0(sp)
    ld   t2, 0(sp)
    li   t1, 0x5a
    bne  t2, t1, fail_call_stack
    li   a0, 0xa5
    ld   ra, 8(sp)
    addi sp, sp, 16
    ret

putstr_timed:
    lbu  t2, 0(a0)
    beqz t2, putstr_done
    sb   t2, 0(t3)
    call char_delay
    addi a0, a0, 1
    j    putstr_timed
putstr_done:
    ret

char_delay:
    li   t5, CLKS_PER_CHAR
char_wait:
    addi t5, t5, -1
    bnez t5, char_wait
    ret

banner_delay:
    li   t5, BANNER_DELAY
banner_wait:
    addi t5, t5, -1
    bnez t5, banner_wait
    ret

fail_ld_const:
    li   t1, 0x0a
    j    fail
fail_sd_ld:
    li   t1, 0x12
    j    fail
fail_lbu:
    li   t1, 0x1a
    j    fail
fail_lhu:
    li   t1, 0x0c
    j    fail
fail_lwu:
    li   t1, 0x14
    j    fail
fail_call_stack:
    li   t1, 0x16
    j    fail
fail:
    sb   t1, 0(t0)
fail_loop:
    j    fail_loop

    .section .rodata
    .balign 8
probe_word:
    .dword 0x1122334455667788
msg_pass:
    .asciz "BRAM SELFTEST PASS\r\n"

    .section .bss
    .balign 8
scratch_area:
    .zero 16
