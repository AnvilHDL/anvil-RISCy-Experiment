# See LICENSE for license details.

#*****************************************************************************
# ecall_mret.S
#-----------------------------------------------------------------------------
#
# Test precise ECALL trap retirement and MRET return sequencing.
#

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 2
  la t0, trap_handler
  csrw mtvec, t0

do_ecall:
  ecall
  j fail

after_ecall:
  TEST_PASSFAIL

trap_handler:
  li t1, 11
  csrr t2, mcause
  bne t1, t2, fail

  la t3, do_ecall
  csrr t4, mepc
  bne t3, t4, fail

  la t5, after_ecall
  csrw mepc, t5
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

RVTEST_DATA_END
