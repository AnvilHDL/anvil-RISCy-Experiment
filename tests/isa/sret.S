# See LICENSE for license details.

#*****************************************************************************
# sret.S
#-----------------------------------------------------------------------------
#
# Test MRET and SRET privilege transitions.
#
# Sequence:
#   1. MRET from M-mode to S-mode (mstatus.MPP=S, mepc=s_entry)
#   2. SRET from S-mode back to S-mode (mstatus.SPP=S, sepc=s_main)
#   3. S-mode ecall fires (cause=9) → trapped to M-mode handler
#   4. Handler verifies cause=9 and mstatus.MPP=S, then returns to M-mode
#

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 2

  # Install M-mode trap handler
  la t0, m_trap_handler
  csrw mtvec, t0

  # Set mstatus.MPP = S (bits[12:11] = 01 = 0x800)
  li t1, 0x800
  csrw mstatus, t1
  la t2, s_entry
  csrw mepc, t2
  mret                          # → S-mode at s_entry

s_entry:
  # In S-mode. Test SRET: set sepc=s_main, SPP=1 (stay in S-mode after SRET).
  la t0, s_main
  csrw sepc, t0
  li t1, 0x100                  # sstatus.SPP bit (bit 8)
  csrrs t2, sstatus, t1         # set SPP=1 (SRET will return to S-mode)
  sret                          # → S-mode at s_main

s_main:
  # Still in S-mode. Confirm with S-mode ecall (cause=9).
  ecall
  j fail

after_sret_test:
  TEST_PASSFAIL

m_trap_handler:
  # Verify cause = 9 (environment call from S-mode)
  li t0, 9
  csrr t1, mcause
  bne t0, t1, fail

  # Verify mstatus.MPP = S: csr_take_exception saved old priv=S into MPP
  li t2, 0x1800                 # MPP field mask (bits[12:11])
  csrr t3, mstatus
  and t3, t3, t2
  li t4, 0x800                  # MPP = S (01)
  bne t3, t4, fail

  # Set MPP=M so MRET returns to M-mode
  li t5, 0x1800
  csrw mstatus, t5
  la t0, after_sret_test
  csrw mepc, t0
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

RVTEST_DATA_END
