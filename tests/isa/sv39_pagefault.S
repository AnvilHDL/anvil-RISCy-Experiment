# sv39_pagefault.S
# Enable Sv39 with only one mapped page, then access an unmapped address.
# Verify the trap handler receives mcause=13 (load page fault).
# Because we stay in M-mode, page faults trap to mtvec.
#
# Note: to get page faults in M-mode the MPRV bit (bit 17) or SUM bit is
# not needed here — mstatus.MPRV=0, so S/U translation applies only to
# non-M-mode accesses.  The pipeline performs Sv39 translation when
# satp.MODE=8 AND priv < M.  Since we're in M-mode after reset, we need
# to drop to S-mode to trigger the fault.  We do this with mret.
#
# Flow:
#   1. Build a minimal page table mapping only 0x80000000 page
#   2. Set mtvec to handler
#   3. Drop to S-mode via mret, set sepc to s_mode_start
#   4. In S-mode: try to load from unmapped 0x80200000 → load page fault
#   5. Handler (runs in M-mode) checks mcause == 13, then exits 0

.section .text
.global main
main:
    # ---- build page table (same as sv39_basic) ----
    li   t0, 0x80000
    slli t0, t0, 10
    ori  t0, t0, 0xCF
    li   t1, 0x80102000
    sd   t0, 0(t1)

    li   t0, 0x80102
    slli t0, t0, 10
    ori  t0, t0, 0x01
    li   t1, 0x80101000
    sd   t0, 0(t1)

    li   t0, 0x80101
    slli t0, t0, 10
    ori  t0, t0, 0x01
    li   t1, 0x80100000
    sd   t0, 16(t1)

    # ---- set mtvec to handler ----
    la   t0, trap_handler
    csrw mtvec, t0

    # ---- enable Sv39 ----
    li   t0, 8
    slli t0, t0, 60
    li   t1, 0x80100
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma

    # ---- drop to S-mode via mret ----
    # mstatus: set MPP=01 (S-mode), MIE=0
    csrr t0, mstatus
    li   t1, ~(3 << 11)     # clear MPP bits
    and  t0, t0, t1
    li   t1, (1 << 11)      # MPP=01 = S-mode
    or   t0, t0, t1
    csrw mstatus, t0

    la   t0, s_mode_start
    csrw mepc, t0
    mret

s_mode_start:
    # Now in S-mode with Sv39 active.
    # Load from an unmapped page → load page fault (mcause=13).
    li   t0, 0x80200000
    ld   t1, 0(t0)          # should trap here

    # If we reach here without trapping, fail.
    li   a0, 2
    li   a7, 93
    ecall

trap_handler:
    # Verify mcause == 13 (load page fault)
    csrr t0, mcause
    li   t1, 13
    bne  t0, t1, wrong_cause

    li   a0, 0
    li   a7, 93
    ecall

wrong_cause:
    li   a0, 1
    li   a7, 93
    ecall
