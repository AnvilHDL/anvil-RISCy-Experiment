# cap_seal.S
# Test SEAL (change cap type to SEALED) and CAPENTER/CAPEXIT (world toggle).
#
# Encoding: (funct5<<27)|(rs2<<20)|(rs1<<15)|(funct3<<12)|(rd<<7)|0x0B
#   MOVC     rd, rs1       funct5=0x08
#   SEAL     rd, rs1, rs2  funct5=0x02  (seal rs1 using rs2 as object-type cap)
#   CAPENTER rd, rs1       funct5=0x10  (set world=SECURE)
#   CAPEXIT  rd, rs1       funct5=0x11  (set world=NORMAL)
#   CBNZ     rd, rs1       funct5=0x15  (rd_int = valid ? 1 : 0)
#   SCC      rd, rs1       funct5=0x01  (rd_int = cursor)
#
# c1 = root cap (LINEAR, NORMAL world)

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 1

  # MOVC c2 = root cap
  # MOVC c2=x2, rs1=x1, rs2=x0: (8<<27)|(0<<20)|(1<<15)|(0<<12)|(2<<7)|0x0B
  .word 0x4000810B

  # MOVC c3 = root cap (will be used as the "type cap" for SEAL)
  # MOVC c3=x3, rs1=x1, rs2=x0: (8<<27)|(0<<20)|(1<<15)|(0<<12)|(3<<7)|0x0B
  .word 0x4000818B

  li TESTNUM, 2

  # ---- test 1: SEAL c4, c2, c3 → cap_a.valid && cap_b.valid → ctype=SEALED ----
  # SEAL c4=x4, rs1=x2, rs2=x3: (2<<27)|(3<<20)|(2<<15)|(0<<12)|(4<<7)|0x0B
  # = (2<<27)=0x10000000, (3<<20)=0x300000, (2<<15)=0x10000, (4<<7)=0x200, 0x0B
  .word 0x1031020B

  # CBNZ a0, c4: a0 = valid (should be 1: both c2 and c3 are valid)
  # CBNZ rd=a0=x10, rs1=x4: (0x15<<27)|(0<<20)|(4<<15)|(0<<12)|(10<<7)|0x0B
  .word 0xA802050B

  li t0, 1
  bne a0, t0, fail

  li TESTNUM, 3

  # ---- test 2: CAPENTER c5, c2 → world becomes SECURE ----
  # CAPENTER c5=x5, rs1=x2, rs2=x0: (0x10<<27)|(0<<20)|(2<<15)|(0<<12)|(5<<7)|0x0B
  # (0x10<<27)=0x80000000, (2<<15)=0x10000, (5<<7)=0x280, 0x0B
  .word 0x8001028B

  # CBNZ a0, c5: should be valid=1
  # CBNZ rd=a0=x10, rs1=x5: (0x15<<27)|(0<<20)|(5<<15)|(0<<12)|(10<<7)|0x0B
  .word 0xA802850B

  li t0, 1
  bne a0, t0, fail

  li TESTNUM, 4

  # ---- test 3: CAPEXIT c6, c5 → world becomes NORMAL ----
  # CAPEXIT c6=x6, rs1=x5, rs2=x0: (0x11<<27)|(0<<20)|(5<<15)|(0<<12)|(6<<7)|0x0B
  # (0x11<<27)=0x88000000, (5<<15)=0x28000, (6<<7)=0x300, 0x0B
  .word 0x8802830B

  # CBNZ a0, c6: should be valid=1
  # CBNZ rd=a0=x10, rs1=x6: (0x15<<27)|(0<<20)|(6<<15)|(0<<12)|(10<<7)|0x0B
  .word 0xA803050B

  li t0, 1
  bne a0, t0, fail

  # SCC a0, c6: cursor should still be 0x80000000
  # SCC rd=a0=x10, rs1=x6: (1<<27)|(0<<20)|(6<<15)|(0<<12)|(10<<7)|0x0B
  .word 0x0803050B

  li t0, 0x80000000
  bne a0, t0, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
