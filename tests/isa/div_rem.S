# See LICENSE for license details.

#*****************************************************************************
# div_rem.S
#-----------------------------------------------------------------------------
#
# Test RV64M DIV/REM operations, including signed, unsigned, W-suffix,
# divide-by-zero, and signed overflow cases.
#

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 2

  li t0, 100
  li t1, 7
  div t2, t0, t1
  li t3, 14
  bne t2, t3, fail
  rem t2, t0, t1
  li t3, 2
  bne t2, t3, fail

  li t0, -100
  li t1, 7
  div t2, t0, t1
  li t3, -14
  bne t2, t3, fail
  rem t2, t0, t1
  li t3, -2
  bne t2, t3, fail

  li t0, -100
  li t1, 7
  divu t2, t0, t1
  li t3, 2635249153387078788
  bne t2, t3, fail
  remu t2, t0, t1
  li t3, 0
  bne t2, t3, fail

  li t0, 0x8000000000000000
  li t1, -1
  div t2, t0, t1
  li t3, 0x8000000000000000
  bne t2, t3, fail
  rem t2, t0, t1
  li t3, 0
  bne t2, t3, fail

  li t0, 123
  li t1, 0
  div t2, t0, t1
  li t3, -1
  bne t2, t3, fail
  rem t2, t0, t1
  li t3, 123
  bne t2, t3, fail

  li t0, -20
  li t1, 6
  divw t2, t0, t1
  li t3, -3
  bne t2, t3, fail
  remw t2, t0, t1
  li t3, -2
  bne t2, t3, fail

  li t0, 0xffffffff
  li t1, 2
  divuw t2, t0, t1
  li t3, 0x7fffffff
  bne t2, t3, fail
  remuw t2, t0, t1
  li t3, 1
  bne t2, t3, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

RVTEST_DATA_END
