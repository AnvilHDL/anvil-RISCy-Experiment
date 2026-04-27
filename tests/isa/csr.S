# See LICENSE for license details.

#*****************************************************************************
# csr.S
#-----------------------------------------------------------------------------
#
# Test basic machine-mode CSR instructions.
#

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 2

  li t0, 0x123
  csrw mscratch, t0
  csrr t1, mscratch
  li t2, 0x123
  bne t1, t2, fail

  li t0, 0x8
  csrrw t3, mstatus, t0
  csrr t4, mstatus
  li t5, 0x8
  bne t4, t5, fail
  bne t3, x0, fail

  li t0, 0x2
  csrrs t6, mstatus, t0
  li t1, 0xa
  csrr t2, mstatus
  bne t6, t5, fail
  bne t2, t1, fail

  li t0, 0x2
  csrrc t3, mstatus, t0
  li t4, 0x8
  csrr t5, mstatus
  bne t3, t1, fail
  bne t5, t4, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

RVTEST_DATA_END
