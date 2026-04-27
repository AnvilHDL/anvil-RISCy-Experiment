# cap_movc.S
# Test MOVC (copy capability) and SCC (read cursor to integer register).
#
# Register convention: cap registers share index space with integer registers.
#   c1 = x1 (ra)  — pre-loaded with root cap by simulator
#   c2 = x2 (sp)  — scratch cap destination
#   c3 = x3 (gp)  — scratch cap destination
#
# Capstone instruction encoding (opcode=0x0B, funct3=0):
#   MOVC rd, rs1, rs2  funct5=0x08
#   SCC  rd, rs1, rs2  funct5=0x01  (rd_int = cap_rf[rs1].cursor)
#
# Encoding: (funct5<<27)|(rs2<<20)|(rs1<<15)|(funct3<<12)|(rd<<7)|0x0B

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 1

  # ---- test 1: MOVC c2, c1, c0 ----------------------------------------
  # c2 = copy of c1 (root cap)
  # MOVC c2=x2, rs1=x1, rs2=x0: (8<<27)|(0<<20)|(1<<15)|(0<<12)|(2<<7)|0x0B
  .word 0x4000810B

  # SCC a0, c2, x0: a0_int = cap_rf[c2].cursor
  # SCC rd=a0=x10, rs1=x2, rs2=x0: (1<<27)|(0<<20)|(2<<15)|(0<<12)|(10<<7)|0x0B
  .word 0x0801050B

  # Root cap cursor = RAM_BASE = 0x80000000
  li t0, 0x80000000
  bne a0, t0, fail

  li TESTNUM, 2

  # ---- test 2: MOVC c3, c2, c0  (chain copy) ----------------------------
  # c3 = copy of c2 (= copy of root)
  # MOVC c3=x3, rs1=x2, rs2=x0: (8<<27)|(0<<20)|(2<<15)|(0<<12)|(3<<7)|0x0B
  .word 0x4001018B

  # SCC a0, c3, x0: a0_int = cap_rf[c3].cursor
  # SCC rd=a0=x10, rs1=x3, rs2=x0: (1<<27)|(0<<20)|(3<<15)|(0<<12)|(10<<7)|0x0B
  .word 0x0801850B

  bne a0, t0, fail   # cursor still 0x80000000

  li TESTNUM, 3

  # ---- test 3: SCC a0, c1 reads cursor of original root cap -------------
  # SCC rd=a0=x10, rs1=x1, rs2=x0: (1<<27)|(0<<20)|(1<<15)|(0<<12)|(10<<7)|0x0B
  .word 0x0800850B

  bne a0, t0, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
