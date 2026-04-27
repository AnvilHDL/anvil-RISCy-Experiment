# cap_domain_switch.S
# Test PC redirection for CJALR, CALL, and RETURN.
#
# Key encoding formula: (funct5<<27)|(rs2<<20)|(rs1<<15)|(funct3<<12)|(rd<<7)|0x0B
#
#   MOVC        rd, rs1, rs2  funct5=0x08
#   SCC         rd, rs1, rs2  funct5=0x01  (rd_int = cap_rf[rs1].cursor)
#   CINCOFFSET  rd, rs1, rs2  funct5=0x05  (rd_cap.cursor = rs1_cap.cursor + rs2_int)
#   SEAL        rd, rs1, rs2  funct5=0x06  (rd_cap = rs1_cap with ctype=SEALED)
#   CJALR       rd, rs1, rs2  funct5=0x04  (PC ← rs1_cap.cursor; rd_cap.cursor = rs2_int)
#   CALL        rd, rs1, rs2  funct5=0x0E  (PC ← rs1_cap.cursor; rd_cap = SEALED_RET)
#   RETURN      rd, rs1, rs2  funct5=0x0F  (PC ← rs1_cap.cursor; rd_cap = LINEAR)
#
# Offset trick: the cap cursor is 0x80000000 = RAM_BASE.  On RV64 "lui t1, 0x80000"
# sign-extends to 0xFFFFFFFF80000000 (negative), so subtraction goes wrong.
# Instead, SCC is used to read the cursor as a positive 64-bit integer, which
# is then subtracted from `la`-derived addresses to get the correct offset.
#
# Test 1: CJALR — PC redirect through a non-sealed capability cursor.
# Test 2: CALL+RETURN — domain switch via a sealed capability.

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  # ── Test 1: CJALR ──────────────────────────────────────────────────────
  li TESTNUM, 1

  # c2 = copy of root cap (cursor=base=0x80000000, end=0x80800000)
  # MOVC c2=x2, rs1=c1=x1: (0x08<<27)|(0<<20)|(1<<15)|(0<<12)|(2<<7)|0x0B
  .word 0x4000810B

  # Read c2.cursor into t1 (x6) as a positive 64-bit integer via SCC.
  # This avoids the sign-extension issue that `lui t1, 0x80000` causes on RV64.
  # SCC t1=x6, rs1=c2=x2, rs2=x0: (0x01<<27)|(0<<20)|(2<<15)|(0<<12)|(6<<7)|0x0B
  .word 0x0801030B

  # Load absolute address of cjalr_target into t0 (x5).
  # `la` expands to auipc+addi, giving a positive 64-bit address.
  la    t0, cjalr_target

  # t0 = cjalr_target - c2.cursor = small positive offset within cap bounds
  sub   t0, t0, t1

  # CINCOFFSET c3=x3, rs1=c2=x2, rs2=t0=x5: c3.cursor = cjalr_target
  # (0x05<<27)|(5<<20)|(2<<15)|(0<<12)|(3<<7)|0x0B
  .word 0x2851018B

  # CJALR c4=x4, cs1=c3=x3, rs2=x0: PC ← c3.cursor = cjalr_target
  # (0x04<<27)|(0<<20)|(3<<15)|(0<<12)|(4<<7)|0x0B
  .word 0x2001820B

  j     fail         # NOT reached if CJALR redirected the PC

cjalr_target:
  # Execution resumes here after CJALR.
  # t1 (x6) still holds c2.cursor = 0x80000000 (integer register preserved through flush).

  # ── Test 2: CALL + RETURN domain switch ──────────────────────────────────
  li TESTNUM, 2

  # c5 = copy of root cap
  # MOVC c5=x5, rs1=c1=x1: (0x08<<27)|(0<<20)|(1<<15)|(0<<12)|(5<<7)|0x0B
  .word 0x4000828B

  # Load address of call_callee; subtract t1 (= RAM_BASE, still valid) for offset.
  la    a1, call_callee
  sub   a1, a1, t1       # a1 = offset from RAM_BASE = call_callee - 0x80000000

  # CINCOFFSET c5=x5, rs1=c5=x5, rs2=a1=x11: c5.cursor = call_callee address
  # (0x05<<27)|(11<<20)|(5<<15)|(0<<12)|(5<<7)|0x0B
  .word 0x28B2828B

  # SEAL c5=x5 in-place using c1 as the type cap: ctype → SEALED.
  # SEAL requires rs2 to be a valid cap; use c1 (the root cap, always valid).
  # funct5=0x02: (0x02<<27)|(1<<20)|(5<<15)|(0<<12)|(5<<7)|0x0B
  .word 0x1012828B

  # Place return address in ra (x1).
  # after_call is 16 bytes below the auipc instruction.
  auipc ra, 0        # ra = address of this instruction
  addi  ra, ra, 16   # ra = after_call (3 instrs ahead: addi, CALL, j fail)

  # CALL c6=x6, cs1=c5=x5, rs2=ra=x1: PC ← c5.cursor = call_callee
  # c6 = SEALED_RET cap with cursor = ra = after_call
  # (0x0E<<27)|(1<<20)|(5<<15)|(0<<12)|(6<<7)|0x0B
  .word 0x7012830B

  j     fail         # NOT reached if CALL redirected the PC

after_call:
  # Execution resumes here after callee executes RETURN.
  TEST_PASSFAIL

  # ── Callee ────────────────────────────────────────────────────────────────
call_callee:
  # c6 = SEALED_RET cap with cursor = after_call (the return address)

  # RETURN c7=x7, cs1=c6=x6, rs2=x0: PC ← c6.cursor = after_call
  # (0x0F<<27)|(0<<20)|(6<<15)|(0<<12)|(7<<7)|0x0B
  .word 0x7803038B

  j     fail         # NOT reached if RETURN redirected the PC

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
