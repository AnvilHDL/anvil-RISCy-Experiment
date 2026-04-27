# cap_cincoffset.S
# Test CINCOFFSET (increment cursor) and bounds enforcement.
#
# Capstone instruction encoding (opcode=0x0B, funct3=0):
#   MOVC         rd, rs1, rs2   funct5=0x08
#   CINCOFFSET   rd, rs1, rs2   funct5=0x05  (rd_cap = rs1_cap with cursor += rs2_int)
#   SCC          rd, rs1, rs2   funct5=0x01  (rd_int = cap_rf[rs1].cursor)
#   CBNZ         rd, rs1, rs2   funct5=0x15  (rd_int = cap_rf[rs1].valid ? 1 : 0)
#
# Encoding: (funct5<<27)|(rs2<<20)|(rs1<<15)|(funct3<<12)|(rd<<7)|0x0B
# Note: rs2 here is the INTEGER register holding the offset.

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 1

  # ---- setup: c2 = copy of root cap (cursor=0x80000000, base=same, end=0x80800000) ----
  # MOVC c2=x2, rs1=x1, rs2=x0
  .word 0x4000810B

  li TESTNUM, 2

  # ---- test 1: CINCOFFSET c3, c2, a0 with a0=4 ----
  li a0, 4
  # CINCOFFSET c3=x3, rs1=x2, rs2=a0=x10: (5<<27)|(10<<20)|(2<<15)|(0<<12)|(3<<7)|0x0B
  .word 0x28A1018B

  # SCC a1, c3: a1 = cap_rf[c3].cursor (should be 0x80000000+4 = 0x80000004)
  # SCC rd=a1=x11, rs1=x3: (1<<27)|(0<<20)|(3<<15)|(0<<12)|(11<<7)|0x0B
  .word 0x0801858B

  li t0, 0x80000004
  bne a1, t0, fail

  li TESTNUM, 3

  # ---- test 2: CINCOFFSET c4, c3, a0 with a0=8 ----
  li a0, 8
  # CINCOFFSET c4=x4, rs1=x3, rs2=a0=x10: (5<<27)|(10<<20)|(3<<15)|(0<<12)|(4<<7)|0x0B
  .word 0x28A1820B

  # SCC a1, c4: a1 = cursor (should be 0x80000004+8 = 0x8000000C)
  # SCC rd=a1=x11, rs1=x4: (1<<27)|(0<<20)|(4<<15)|(0<<12)|(11<<7)|0x0B
  .word 0x0802058B

  li t0, 0x8000000C
  bne a1, t0, fail

  li TESTNUM, 4

  # ---- test 3: CINCOFFSET out of bounds → invalid cap ----
  # Offset by 0x800001 (1 byte past end=0x80800000 from base cursor=0x80000000)
  # end_ = 0x80800000, cursor+offset = 0x80800001 > end_ → invalidated
  li a0, 0x800001
  # CINCOFFSET c5=x5, rs1=x2, rs2=a0=x10: (5<<27)|(10<<20)|(2<<15)|(0<<12)|(5<<7)|0x0B
  .word 0x28A1028B

  # CBNZ a1, c5: a1 = cap_rf[c5].valid (should be 0 since out of bounds)
  # CBNZ rd=a1=x11, rs1=x5: (0x15<<27)|(0<<20)|(5<<15)|(0<<12)|(11<<7)|0x0B
  .word 0xA802858B

  # Expect valid=0 (invalidated due to out-of-bounds cursor)
  bne a1, x0, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
