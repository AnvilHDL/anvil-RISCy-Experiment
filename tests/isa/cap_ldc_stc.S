# cap_ldc_stc.S
# Test LDC (load capability from memory) and STC (store capability to memory).
#
# Encoding: (funct5<<27)|(rs2<<20)|(rs1<<15)|(funct3<<12)|(rd<<7)|0x0B
#   MOVC    funct5=0x08  rd_cap = rs1_cap (copy)
#   SCC     funct5=0x01  rd_int = cap_rf[rs1].cursor
#   CBNZ    funct5=0x15  rd_int = cap_rf[rs1].valid ? 1 : 0
#   STC     funct5=0x0D  host_mem[rs1_int] = cap_rf[rs2]; rd_int = addr
#   LDC     funct5=0x0C  cap_rf[rd] = host_mem[rs1_int]
#
# Capability slots are 32-byte-aligned in memory.
# Test address: RAM_BASE + 0x700000 = 0x80700000 (well within 8 MB window).

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 1

  # c2 = copy of root cap (cursor=0x80000000)
  # MOVC c2=x2, rs1=x1: (8<<27)|(0<<20)|(1<<15)|(0<<12)|(2<<7)|0x0B
  .word 0x4000810B

  li TESTNUM, 2

  # ---- test 1: STC c2 to address 0x80700000 ----
  # a0 = store address (must be 32-byte aligned)
  li a0, 0x80700000

  # STC rd=x10, rs1=a0=x10, rs2=c2=x2: (0x0D<<27)|(2<<20)|(10<<15)|(0<<12)|(10<<7)|0x0B
  # (0x0D<<27)=0x68000000 (2<<20)=0x00200000 (10<<15)=0x00050000 (10<<7)=0x00000500
  .word 0x6825050B

  # a0 now = 0x80700000 (STC writes address to rd)
  li TESTNUM, 3

  # ---- test 2: LDC c3 from address 0x80700000 ----
  li a0, 0x80700000

  # LDC c3=x3, rs1=a0=x10: (0x0C<<27)|(0<<20)|(10<<15)|(0<<12)|(3<<7)|0x0B
  # (0x0C<<27)=0x60000000 (10<<15)=0x00050000 (3<<7)=0x00000180
  .word 0x6005018B

  # CBNZ a1, c3: should be 1 (loaded cap is valid)
  # CBNZ rd=a1=x11, rs1=x3: (0x15<<27)|(0<<20)|(3<<15)|(0<<12)|(11<<7)|0x0B
  # (11<<7)=0x00000580
  .word 0xA801858B

  li t0, 1
  bne a1, t0, fail

  # SCC a1, c3: cursor should be 0x80000000 (same as c2)
  # SCC rd=a1=x11, rs1=x3: (1<<27)|(0<<20)|(3<<15)|(0<<12)|(11<<7)|0x0B
  .word 0x0801858B

  li t0, 0x80000000
  bne a1, t0, fail

  li TESTNUM, 4

  # ---- test 3: LDC from untagged memory → invalid cap ----
  # Use a different address that has never been STC'd
  li a0, 0x80700020   # next 32-byte slot (was never STC'd → tag=0)

  # LDC c4=x4, rs1=a0=x10: (0x0C<<27)|(0<<20)|(10<<15)|(0<<12)|(4<<7)|0x0B
  # (4<<7)=0x00000200
  .word 0x6005020B

  # CBNZ a1, c4: should be 0 (untagged slot → invalid)
  # CBNZ rd=a1=x11, rs1=x4: (0x15<<27)|(0<<20)|(4<<15)|(0<<12)|(11<<7)|0x0B
  .word 0xA802058B

  bne a1, x0, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
