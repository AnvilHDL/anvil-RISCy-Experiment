#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

fail=0

require_pattern() {
  local label="$1"
  local pattern="$2"
  local file="$3"

  if rg -q "$pattern" "$ROOT/$file"; then
    printf '[fpga-boundary] documented: %s\n' "$label"
  else
    printf '[fpga-boundary] missing documentation for: %s (%s)\n' "$label" "$file" >&2
    fail=1
  fi
}

require_harness_pattern() {
  local label="$1"
  local pattern="$2"

  if rg -q "$pattern" "$ROOT/sim/sim_main.cpp"; then
    printf '[fpga-boundary] simulation-backed present: %s\n' "$label"
  else
    printf '[fpga-boundary] simulation-backed hook not found: %s\n' "$label" >&2
    fail=1
  fi
}

require_absent_pattern() {
  local label="$1"
  local pattern="$2"
  local file="$3"

  if rg -q "$pattern" "$ROOT/$file"; then
    printf '[fpga-boundary] forbidden stale harness path found: %s (%s)\n' "$label" "$file" >&2
    fail=1
  else
    printf '[fpga-boundary] absent as expected: %s\n' "$label"
  fi
}

require_absent_file() {
  local label="$1"
  local file="$2"

  if [ -e "$ROOT/$file" ]; then
    printf '[fpga-boundary] forbidden stale file found: %s (%s)\n' "$label" "$file" >&2
    fail=1
  else
    printf '[fpga-boundary] absent as expected: %s\n' "$label"
  fi
}

require_harness_pattern "host RAM model" "static std::uint8_t host_mem\\[RAM_SIZE\\]"
require_harness_pattern "Sv39 software TLB/PTW" "static Sv39Tlb sv39_tlb"
require_harness_pattern "MMIO store dispatcher" "dispatch_mmio_store"
require_harness_pattern "virtio-blk image model" "process_virtio_queue_notify"
require_harness_pattern "capability shadow RF" "static CapabilityT cap_rf\\[32\\]"
require_harness_pattern "capability WB emulation" "commit_cap_wb"

require_absent_pattern "DIV/REM result patching in harness" "patch_div|capture_div|DIV-DBG" "sim/sim_main.cpp"
require_absent_pattern "custom scalar CCSR harness state" "ccsr\\[" "sim/sim_main.cpp"
require_absent_pattern "timer compare state in harness" "sim_mtimecmp" "sim/sim_main.cpp"

require_pattern "Verilator is not FPGA readiness" "FPGA-ready processor" "FPGA_READINESS.md"
require_pattern "host_mem replacement" "host_mem\\[\\]" "FPGA_READINESS.md"
require_pattern "Sv39 RTL replacement" "RTL TLB plus multi-cycle PTW FSM" "FPGA_READINESS.md"
require_pattern "MMIO/peripheral RTL replacement" "RTL peripherals or bus adapters" "FPGA_READINESS.md"
require_pattern "RTL timer ownership" 'RTL `mtime`/`mtimecmp`/`stimecmp`' "FPGA_READINESS.md"
require_pattern "capability RF RTL replacement" "RTL capability RF" "FPGA_READINESS.md"
require_pattern "xv6 smoke environment" "RUN_XV6=1" "FPGA_READINESS.md"
require_pattern "Genesys 2 target" "Genesys 2" "FPGA_READINESS.md"
require_pattern "FPGA RTL export command" "scripts/export_fpga_rtl.sh" "FPGA_READINESS.md"
require_pattern "BRAM bring-up target" "BRAM bring-up target" "FPGA_READINESS.md"
require_pattern "no demo RTL memories policy" "should not contain demo instruction/data memories" "FPGA_READINESS.md"
require_pattern "wrapper non-production behavior" "UART TX-only debug path" "FPGA_READINESS.md"
require_pattern "Capstone RTL gap" "cap_result.*zeroed" "FPGA_READINESS.md"

require_pattern "Genesys 2 constraints" "XC7K325T-2FFG900C" "fpga/constraints/genesys2.xdc"
require_pattern "Genesys 2 wrapper honesty" "synthesis smoke target" "fpga/src/risky_genesys2_top.sv"
require_pattern "BRAM wrapper core bridge" "pipeline_core_bram_if" "fpga/src/risky_genesys2_bram_top.sv"
require_pattern "BRAM bitstream target" "bitstream-bram" "fpga/Makefile"
require_pattern "BRAM local programming target" "program-bram" "fpga/Makefile"
require_absent_pattern "ambiguous placeholder language in FPGA wrapper" "dummy|placeholder|TODO|FIXME|HACK" "fpga/src/risky_genesys2_top.sv"
require_absent_pattern "ambiguous placeholder language in BRAM wrapper" "dummy|placeholder|TODO|FIXME|HACK" "fpga/src/risky_genesys2_bram_top.sv"
require_absent_file "demo instruction memory RTL file" "src/core/fetch/imem.anvil"
require_absent_pattern "demo instruction memory RTL import" "demo_imem|Hand-written instruction memory|fetch/imem" "src/core/top/pipeline_core.anvil"

if [ "$fail" -ne 0 ]; then
  printf '[fpga-boundary] FAILED\n' >&2
  exit 1
fi

printf '[fpga-boundary] boundary check passed\n'
