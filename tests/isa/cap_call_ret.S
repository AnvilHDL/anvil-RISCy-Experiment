# cap_call_ret.S
# Test CALL (produce SEALED_RET cap, set cursor) and RETURN (produce LINEAR cap, redirect PC).
#
# Encoding: (funct5<<27)|(rs2<<20)|(rs1<<15)|(funct3<<12)|(rd<<7)|0x0B
#   MOVC    funct5=0x08  rd_cap = rs1_cap
#   CALL    funct5=0x0E  rd_cap.ctype=SEALED_RET; rd_cap.cursor=rs2_int; PC←rs1_cap.cursor only if rs1=SEALED
#   RETURN  funct5=0x0F  rd_cap.ctype=LINEAR;     rd_cap.cursor=rs2_int; PC←rs1_cap.cursor only if rs1=SEALED_RET
#   CBNZ    funct5=0x15  rd_int = cap_rf[rs1].valid ? 1 : 0
#   SCC     funct5=0x01  rd_int = cap_rf[rs1].cursor
#
# Test 1: CALL on a LINEAR cap (no redirect; just verifies the type transformation).
# Test 2: RETURN on the resulting SEALED_RET cap with a proper in-code return target
#         (verifies both the type transformation and the PC redirect).

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 1

  # c2 = copy of root cap (LINEAR type; cursor=0x80000000)
  # MOVC c2=x2, rs1=c1=x1: (8<<27)|(0<<20)|(1<<15)|(0<<12)|(2<<7)|0x0B
  .word 0x4000810B

  li TESTNUM, 2

  # ── Test 1: CALL on a LINEAR cap ──────────────────────────────────────────
  # rs1=c2 is LINEAR so NO PC redirect fires.  The result cap c3 gets
  # ctype=SEALED_RET and cursor=a0 (0x80001000).
  li a0, 0x80001000
  # CALL c3=x3, rs1=c2=x2, rs2=a0=x10: (0x0E<<27)|(10<<20)|(2<<15)|(0<<12)|(3<<7)|0x0B
  .word 0x70A1018B

  # CBNZ a0, c3: valid should be 1
  # CBNZ rd=a0=x10, rs1=x3: (0x15<<27)|(0<<20)|(3<<15)|(0<<12)|(10<<7)|0x0B
  .word 0xA801850B
  li t0, 1
  bne a0, t0, fail

  # SCC a0, c3: cursor should be 0x80001000
  # SCC rd=a0=x10, rs1=x3: (1<<27)|(0<<20)|(3<<15)|(0<<12)|(10<<7)|0x0B
  .word 0x0801850B
  li t0, 0x80001000
  bne a0, t0, fail

  li TESTNUM, 3

  # ── Test 2: RETURN on SEALED_RET cap — type transform + PC redirect ────────
  # Build a new SEALED_RET cap c5 whose cursor points to return_target below.
  # Use a PC-relative relocation instead of a hand-counted byte offset so the
  # target stays correct across assembler/toolchain differences.
1:
  auipc t0, %pcrel_hi(return_target)
  addi  t0, t0, %pcrel_lo(1b)

  # CALL c5=x5, rs1=c2=x2, rs2=t0=x5: c5 = SEALED_RET(cursor=return_target), no redirect
  # (0x0E<<27)|(5<<20)|(2<<15)|(0<<12)|(5<<7)|0x0B
  .word 0x7051028B

  li a1, 0x80002000

  # RETURN c4=x4, rs1=c5=x5, rs2=a1=x11: PC ← c5.cursor = return_target
  # c4 = LINEAR cap with cursor = a1 = 0x80002000
  # (0x0F<<27)|(11<<20)|(5<<15)|(0<<12)|(4<<7)|0x0B
  .word 0x78B2820B

  j     fail         # NOT reached if RETURN redirected the PC

return_target:
  # Execution resumes here after RETURN.

  # CBNZ a0, c4: valid should be 1
  # CBNZ rd=a0=x10, rs1=c4=x4: (0x15<<27)|(0<<20)|(4<<15)|(0<<12)|(10<<7)|0x0B
  .word 0xA802050B
  li t0, 1
  bne a0, t0, fail

  # SCC a0, c4: cursor should be 0x80002000
  # SCC rd=a0=x10, rs1=c4=x4: (1<<27)|(0<<20)|(4<<15)|(0<<12)|(10<<7)|0x0B
  .word 0x0802050B
  li t0, 0x80002000
  bne a0, t0, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
