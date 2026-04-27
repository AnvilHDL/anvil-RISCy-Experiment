# See LICENSE for license details.

#*****************************************************************************
# ebreak.S
#-----------------------------------------------------------------------------
#
# Test EBREAK exception: cause=3, mepc=ebreak PC.
#

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 2
  la t0, trap_handler
  csrw mtvec, t0

do_ebreak:
  ebreak
  j fail

after_ebreak:
  TEST_PASSFAIL

trap_handler:
  # Verify cause = 3 (breakpoint)
  li t1, 3
  csrr t2, mcause
  bne t1, t2, fail

  # Verify mepc points at the ebreak instruction
  la t3, do_ebreak
  csrr t4, mepc
  bne t3, t4, fail

  la t5, after_ebreak
  csrw mepc, t5
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

RVTEST_DATA_END
