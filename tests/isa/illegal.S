# See LICENSE for license details.

#*****************************************************************************
# illegal.S
#-----------------------------------------------------------------------------
#
# Test illegal instruction exception: cause=2, mepc=faulting PC.
#

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 2
  la t0, trap_handler
  csrw mtvec, t0

do_illegal:
  .word 0x00000000          # encoding 0x0 is an illegal opcode
  j fail

after_illegal:
  TEST_PASSFAIL

trap_handler:
  # Verify cause = 2 (illegal instruction)
  li t1, 2
  csrr t2, mcause
  bne t1, t2, fail

  # Verify mepc points at the illegal instruction
  la t3, do_illegal
  csrr t4, mepc
  bne t3, t4, fail

  la t5, after_illegal
  csrw mepc, t5
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

RVTEST_DATA_END
