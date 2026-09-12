# cap_shrink.S
# Test SHRINK (narrow capability bounds).
#
# Encoding: (funct5<<27)|(rs2<<20)|(rs1<<15)|(funct3<<12)|(rd<<7)|0x0B
#   MOVC    rd, rs1   funct5=0x08  (rs2 ignored, use x0)
#   SHRINK  rd, rs1, rs2  funct5=0x06  (intersect bounds of rs1 and rs2 caps)
#   SCC     rd, rs1   funct5=0x01  (rd_int = cap_rf[rs1].cursor)
#   CBNZ    rd, rs1   funct5=0x15  (rd_int = cap_rf[rs1].valid ? 1 : 0)
#
# c1 = root cap: base=0x80000000, end=0x80800000, cursor=0x80000000
# SHRINK c4, c2, c2 preserves c2's bounds and validity.

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 1

  # Setup: MOVC c2 = root cap
  # MOVC c2=x2, rs1=x1, rs2=x0: (8<<27)|(0<<20)|(1<<15)|(0<<12)|(2<<7)|0x0B
  .word 0x4000810B

  # MOVC c3 = root cap (same bounds as c2)
  # MOVC c3=x3, rs1=x1, rs2=x0: (8<<27)|(0<<20)|(1<<15)|(0<<12)|(3<<7)|0x0B
  .word 0x4000818B

  li TESTNUM, 2

  # ---- test 1: SHRINK c4, c2, c3 → same bounds (both are root cap) ----
  # SHRINK c4=x4, rs1=x2, rs2=x3: (6<<27)|(3<<20)|(2<<15)|(0<<12)|(4<<7)|0x0B
  .word 0x3031020B

  # CBNZ a0, c4: a0_int = cap_rf[c4].valid (should be 1)
  # CBNZ rd=a0=x10, rs1=x4: (0x15<<27)|(0<<20)|(4<<15)|(0<<12)|(10<<7)|0x0B
  .word 0xA802050B

  li t0, 1
  bne a0, t0, fail

  # SCC a0, c4: cursor = 0x80000000 (base, since shrink clamps cursor to [base,end])
  # SCC rd=a0=x10, rs1=x4: (1<<27)|(0<<20)|(4<<15)|(0<<12)|(10<<7)|0x0B
  .word 0x0802050B

  li t0, 0x80000000
  bne a0, t0, fail

  li TESTNUM, 3

  # ---- test 2: SHRINK with one invalidated cap → result is invalid ----
  # First: CINCOFFSET to push cursor past end to get invalid cap in c5
  li a0, 0x800001
  # CINCOFFSET c5=x5, rs1=x2, rs2=a0=x10: (5<<27)|(10<<20)|(2<<15)|(0<<12)|(5<<7)|0x0B
  .word 0x28A1028B

  # SHRINK c6, c5, c2: c5 is invalid → cap_a.valid=0 → result is zero_cap (invalid)
  # SHRINK c6=x6, rs1=x5, rs2=x2: (6<<27)|(2<<20)|(5<<15)|(0<<12)|(6<<7)|0x0B
  .word 0x3022830B

  # CBNZ a0, c6: should be 0 (invalid)
  # CBNZ rd=a0=x10, rs1=x6: (0x15<<27)|(0<<20)|(6<<15)|(0<<12)|(10<<7)|0x0B
  .word 0xA803050B

  bne a0, x0, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
