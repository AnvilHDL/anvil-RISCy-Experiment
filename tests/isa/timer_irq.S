# See LICENSE for license details.

#*****************************************************************************
# timer_irq.S
#-----------------------------------------------------------------------------
#
# Test machine timer interrupt (MTIP, mcause = 0x8000000000000007).
#
# The simulation harness fires MTIP when sim_mtime >= sim_mtimecmp.
# Tests write a delay value (in cycles) to physical address 0x80001FF0;
# the harness sets sim_mtimecmp = sim_mtime + delay when it reads a
# non-zero value there.  The test uses delay=500 to give the setup code
# (mtvec/mie/mstatus writes) enough time to complete before MTIP fires.
#

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN

  li TESTNUM, 2

  # Set mtvec to handler (direct mode).
  la   t0, trap_handler
  csrw mtvec, t0

  # Signal harness to fire MTIP ~500 cycles from now.
  li   t0, 500
  li   t1, 0x80001FF0
  sd   t0, 0(t1)

  # Enable machine timer interrupt: mie.MTIE = bit 7.
  li   t0, (1 << 7)
  csrw mie, t0

  # Enable global M-mode interrupts: mstatus.MIE = bit 3.
  li   t0, (1 << 3)
  csrs mstatus, t0

  # Spin until the interrupt fires.
spin:
  j    spin

  # Should not reach here.
  j fail

trap_handler:
  # Verify bit 63 (interrupt flag) is set.
  csrr t0, mcause
  srli t1, t0, 63
  li   t2, 1
  bne  t1, t2, fail

  # Verify interrupt code == 7 (machine timer).
  slli t0, t0, 1      # shift out bit 63
  srli t0, t0, 1      # now bits[62:0] = interrupt code
  li   t2, 7
  bne  t0, t2, fail

  # Disable timer interrupt so we don't loop forever.
  csrw mie, zero

  TEST_PASSFAIL

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

RVTEST_DATA_END
