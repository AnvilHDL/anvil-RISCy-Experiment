# cap_revoke.S
# Test MREV (mint revocation token) and REVOKE (sweep capabilities by epoch).
#
# Capstone instruction encoding (opcode=0x0B, funct3=0):
#   MOVC   rd, rs1, rs2  funct5=0x08  (rd_cap = copy of rs1_cap)
#   CBNZ   rd, rs1, rs2  funct5=0x15  (rd_int = cap_rf[rs1].valid ? 1 : 0)
#   MREV   rd, rs1, rs2  funct5=0x14  (c2_new_epoch; rd_cap = REVOC token for rs1)
#   REVOKE rd, rs1, rs2  funct5=0x0A  (sweep all caps sharing revoc token epoch)
#
# Encoding: (funct5<<27)|(rs2<<20)|(rs1<<15)|(funct3<<12)|(rd<<7)|0x0B
#
# Setup:
#   c1 = root cap (pre-loaded by simulator, epoch=0)
#   c2 = MOVC(c1)  -- will be epoch-stamped by MREV
#   c3 = MOVC(c1)  -- pre-MREV copy, retains epoch=0, must survive REVOKE
#   c4 = MREV(c2)  -- REVOC token; c2 also gets new epoch
#   c5 = MOVC(c2)  -- derived after MREV, inherits new epoch, must be revoked

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  # ---- setup ----------------------------------------------------------------
  # MOVC c2=x2, rs1=x1: (0x08<<27)|(0<<20)|(1<<15)|(0<<12)|(2<<7)|0x0B
  .word 0x4000810B

  # MOVC c3=x3, rs1=x1: (0x08<<27)|(0<<20)|(1<<15)|(0<<12)|(3<<7)|0x0B
  .word 0x4000818B

  # MREV c4=x4, rs1=c2=x2: (0x14<<27)|(0<<20)|(2<<15)|(0<<12)|(4<<7)|0x0B
  # Stamps c2 with a new epoch; c4 becomes the REVOC token for that epoch.
  .word 0xA001020B

  # MOVC c5=x5, rs1=c2=x2: (0x08<<27)|(0<<20)|(2<<15)|(0<<12)|(5<<7)|0x0B
  # c5 inherits the new epoch from c2 (post-MREV copy).
  .word 0x4001028B

  # ---- tests 1-4: pre-REVOKE validity checks --------------------------------

  li TESTNUM, 1
  # c3 was derived before MREV; it retains epoch=0 and should be valid.
  # CBNZ a0=x10, rs1=c3=x3: (0x15<<27)|(0<<20)|(3<<15)|(0<<12)|(10<<7)|0x0B
  .word 0xA801850B
  beqz a0, fail

  li TESTNUM, 2
  # MREV must have produced a valid REVOC cap in c4.
  # CBNZ a0=x10, rs1=c4=x4: (0x15<<27)|(0<<20)|(4<<15)|(0<<12)|(10<<7)|0x0B
  .word 0xA802050B
  beqz a0, fail

  li TESTNUM, 3
  # c2 itself must still be valid (MREV does not invalidate the source cap).
  # CBNZ a0=x10, rs1=c2=x2: (0x15<<27)|(0<<20)|(2<<15)|(0<<12)|(10<<7)|0x0B
  .word 0xA801050B
  beqz a0, fail

  li TESTNUM, 4
  # c5 was derived from c2 after MREV; it should be valid before any REVOKE.
  # CBNZ a0=x10, rs1=c5=x5: (0x15<<27)|(0<<20)|(5<<15)|(0<<12)|(10<<7)|0x0B
  .word 0xA802850B
  beqz a0, fail

  # ---- REVOKE ---------------------------------------------------------------
  # REVOKE x0, rs1=c4=x4, rs2=x0: (0x0A<<27)|(0<<20)|(4<<15)|(0<<12)|(0<<7)|0x0B
  # Sweeps all caps sharing c4's epoch; also consumes c4 itself.
  .word 0x5002000B

  # ---- tests 5-8: post-REVOKE validity checks --------------------------------

  li TESTNUM, 5
  # c5 shared c2's (new) epoch → must be invalid after REVOKE.
  # CBNZ a0=x10, rs1=c5=x5
  .word 0xA802850B
  bnez a0, fail

  li TESTNUM, 6
  # c3 had epoch=0 (pre-MREV); it must survive REVOKE unchanged.
  # CBNZ a0=x10, rs1=c3=x3
  .word 0xA801850B
  beqz a0, fail

  li TESTNUM, 7
  # The REVOC token c4 must be consumed (zeroed) by REVOKE.
  # CBNZ a0=x10, rs1=c4=x4
  .word 0xA802050B
  bnez a0, fail

  li TESTNUM, 8
  # c2 shared the new epoch (stamped by MREV) → must be invalid after REVOKE.
  # CBNZ a0=x10, rs1=c2=x2
  .word 0xA801050B
  bnez a0, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
