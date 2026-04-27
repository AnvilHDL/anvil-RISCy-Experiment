# cap_illegal.S
# Test that an unknown Capstone funct5 causes an illegal-instruction trap.
#
# funct5=0x1F is reserved/undefined → trap cause=2 (illegal instruction).
# We install a custom M-mode handler that advances mepc+4 and sets a0=1.
# After mret we verify a0==1.  If no trap fires a0 stays 0 → bne catches it.

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 1

  # Install custom mtvec (direct mode)
  la   t0, illegal_handler
  csrw mtvec, t0

  li   a0, 0          # sentinel — handler will set to 1

  # funct5=0x1F is unused → illegal instruction trap
  # (0x1F<<27)|(0<<20)|(0<<15)|(0<<12)|(0<<7)|0x0B = 0xF800000B
  .word 0xF800000B

  # mret lands here (mepc was advanced +4 by handler)
  li TESTNUM, 2
  li t0, 1
  bne a0, t0, fail    # a0 must be 1 (trap was taken)

  TEST_PASSFAIL

illegal_handler:
  # Advance mepc past the offending instruction and return
  csrr t1, mepc
  addi t1, t1, 4
  csrw mepc, t1
  li   a0, 1
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
