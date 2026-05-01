# cap_ccsr.S
# Test Capstone custom CSRs:
#   0xBC0 = ceh        (capability exception handler address)
#   0xBC1 = cinit      (initial capability for new domains)
#   0xBC2 = epc        (capability exception PC)
#   0xBC3 = switch_cap (domain-switch capability)
#
# These CSRs are implemented by the RTL CSR path and support normal
# CSRRW/CSRRS/CSRRC semantics.
#
# Tests:
#   1. CSRRW ceh (0xBC0): write value, read it back.
#   2. CSRRW cinit (0xBC1): write and read back.
#   3. CSRRW epc (0xBC2): write and read back.
#   4. CSRRW switch_cap (0xBC3): write and read back.
#   5. CSRRS ceh: set bits.
#   6. CSRRC ceh: clear bits.

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 1

  # ---- test 1: CSRRW ceh (0xBC0) ----
  li   t1, 0xDEAD0000
  csrrw a0, 0xBC0, t1      # a0 = old ceh (should be 0), ceh = 0xDEAD0000
  bne  a0, x0, fail        # old value must be 0

  csrr a0, 0xBC0           # read back
  li   t0, 0xDEAD0000
  bne  a0, t0, fail

  li TESTNUM, 2

  # ---- test 2: CSRRW cinit (0xBC1) ----
  li   t1, 0xBEEF0001
  csrrw a0, 0xBC1, t1
  bne  a0, x0, fail

  csrr a0, 0xBC1
  li   t0, 0xBEEF0001
  bne  a0, t0, fail

  li TESTNUM, 3

  # ---- test 3: CSRRW epc (0xBC2) ----
  li   t1, 0xCAFE0002
  csrrw a0, 0xBC2, t1
  bne  a0, x0, fail

  csrr a0, 0xBC2
  li   t0, 0xCAFE0002
  bne  a0, t0, fail

  li TESTNUM, 4

  # ---- test 4: CSRRW switch_cap (0xBC3) ----
  li   t1, 0xF00D0003
  csrrw a0, 0xBC3, t1
  bne  a0, x0, fail

  csrr a0, 0xBC3
  li   t0, 0xF00D0003
  bne  a0, t0, fail

  li TESTNUM, 5

  # ---- test 5: CSRRS ceh — set bits ----
  # ceh currently = 0xDEAD0000; OR with 0xFF → 0xDEAD00FF
  li   t1, 0xFF
  csrrs a0, 0xBC0, t1      # a0 = old = 0xDEAD0000; ceh |= 0xFF
  li   t0, 0xDEAD0000
  bne  a0, t0, fail

  csrr a0, 0xBC0
  li   t0, 0xDEAD00FF
  bne  a0, t0, fail

  li TESTNUM, 6

  # ---- test 6: CSRRC ceh — clear bits ----
  # ceh = 0xDEAD00FF; clear 0xFF → 0xDEAD0000
  li   t1, 0xFF
  csrrc a0, 0xBC0, t1      # a0 = old = 0xDEAD00FF; ceh &= ~0xFF
  li   t0, 0xDEAD00FF
  bne  a0, t0, fail

  csrr a0, 0xBC0
  li   t0, 0xDEAD0000
  bne  a0, t0, fail

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
