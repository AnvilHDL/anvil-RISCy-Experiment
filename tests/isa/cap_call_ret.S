# cap_call_ret.S
# Test CALL (seal with SEALED_RET type, set cursor) and RETURN (unseal to LINEAR).
#
# Encoding: (funct5<<27)|(rs2<<20)|(rs1<<15)|(funct3<<12)|(rd<<7)|0x0B
#   MOVC    funct5=0x08  rd_cap = rs1_cap
#   CALL    funct5=0x0E  rd_cap = rs1_cap; ctype=SEALED_RET; cursor=rs2_int
#   RETURN  funct5=0x0F  rd_cap = rs1_cap; ctype=LINEAR;     cursor=rs2_int
#   CBNZ    funct5=0x15  rd_int = cap_rf[rs1].valid ? 1 : 0
#   SCC     funct5=0x01  rd_int = cap_rf[rs1].cursor

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 1

  # c2 = copy of root cap (LINEAR)
  # MOVC c2=x2, rs1=x1: (8<<27)|(0<<20)|(1<<15)|(0<<12)|(2<<7)|0x0B
  .word 0x4000810B

  li TESTNUM, 2

  # ---- test 1: CALL c3, c2, a0 (cursor=0x80001000) ----
  li a0, 0x80001000
  # CALL c3=x3, rs1=x2, rs2=a0=x10: (0x0E<<27)|(10<<20)|(2<<15)|(0<<12)|(3<<7)|0x0B
  # (0x0E<<27)=0x70000000 (10<<20)=0x00A00000 (2<<15)=0x00010000 (3<<7)=0x00000180
  .word 0x70A1018B

  # CBNZ a0, c3: valid should be 1
  # CBNZ rd=a0=x10, rs1=x3: (0x15<<27)|(0<<20)|(3<<15)|(0<<12)|(10<<7)|0x0B
  # (0x15<<27)=0xA8000000 (3<<15)=0x00018000 (10<<7)=0x00000500
  .word 0xA801850B

  li t0, 1
  bne a0, t0, fail

  # SCC a0, c3: cursor should be 0x80001000
  # SCC rd=a0=x10, rs1=x3: (1<<27)|(0<<20)|(3<<15)|(0<<12)|(10<<7)|0x0B
  # (1<<27)=0x08000000
  .word 0x0801850B

  li t0, 0x80001000
  bne a0, t0, fail

  li TESTNUM, 3

  # ---- test 2: RETURN c4, c3, a1 (cursor=0x80002000) ----
  li a1, 0x80002000
  # RETURN c4=x4, rs1=x3, rs2=a1=x11: (0x0F<<27)|(11<<20)|(3<<15)|(0<<12)|(4<<7)|0x0B
  # (0x0F<<27)=0x78000000 (11<<20)=0x00B00000 (3<<15)=0x00018000 (4<<7)=0x00000200
  .word 0x78B1820B

  # CBNZ a0, c4: valid should be 1
  # CBNZ rd=a0=x10, rs1=x4: (0x15<<27)|(0<<20)|(4<<15)|(0<<12)|(10<<7)|0x0B
  # (4<<15)=0x00020000
  .word 0xA802050B

  li t0, 1
  bne a0, t0, fail

  # SCC a0, c4: cursor should be 0x80002000
  # SCC rd=a0=x10, rs1=x4: (1<<27)|(0<<20)|(4<<15)|(0<<12)|(10<<7)|0x0B
  .word 0x0802050B

  li t0, 0x80002000
  bne a0, t0, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
