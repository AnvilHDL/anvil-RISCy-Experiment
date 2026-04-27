# See LICENSE for license details.

#*****************************************************************************
# misalign_load.S
#-----------------------------------------------------------------------------
#
# Test load address misaligned exception: cause=4, tval=faulting address.
#

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 2
  la t0, trap_handler
  csrw mtvec, t0

  # Build a 4-byte-aligned base, then add 1 → misaligned word address
  la t0, test_data
  addi t0, t0, 1            # t0 = misaligned address (keep for handler check)

do_load:
  lw t1, 0(t0)              # should trap: cause=4, tval=t0
  j fail

after_load:
  TEST_PASSFAIL

trap_handler:
  # Verify cause = 4 (load address misaligned)
  li t1, 4
  csrr t2, mcause
  bne t1, t2, fail

  # Verify tval = the misaligned address (still in t0)
  csrr t3, mtval
  bne t0, t3, fail

  la t4, after_load
  csrw mepc, t4
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
test_data:
  .word 0xdeadbeef

RVTEST_DATA_END
