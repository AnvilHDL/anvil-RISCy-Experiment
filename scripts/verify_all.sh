#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${VERIFY_BUILD_TIMEOUT:=20m}"
: "${VERIFY_TEST_TIMEOUT:=5m}"

run_with_timeout() {
  local limit="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$limit" "$@"
  else
    "$@"
  fi
}

echo "[verify] shell syntax"
bash -n "$ROOT"/scripts/*.sh
bash -n "$ROOT"/fpga/scripts/*.sh

echo "[verify] FPGA boundary documentation"
"$ROOT/scripts/check_fpga_boundary.sh"

echo "[verify] simulator build"
SIM_BIN="$(run_with_timeout "$VERIFY_BUILD_TIMEOUT" "$ROOT/scripts/build_program_sim.sh")"
export SIM_BIN

echo "[verify] ISA regression"
run_with_timeout "$VERIFY_TEST_TIMEOUT" "$ROOT/scripts/run_riscv_tests.sh"

echo "[verify] C++ program regression"
run_with_timeout "$VERIFY_TEST_TIMEOUT" "$ROOT/scripts/run_program_tests.sh"

echo "[verify] generated SystemVerilog lint"
run_with_timeout "$VERIFY_TEST_TIMEOUT" "$ROOT/scripts/lint_generated_sv.sh"

echo "[verify] FPGA RTL export/lint"
run_with_timeout "$VERIFY_TEST_TIMEOUT" "$ROOT/scripts/lint_fpga_rtl.sh"

if [ "${RUN_XV6:-0}" = "1" ]; then
  echo "[verify] xv6 smoke"
  run_with_timeout "${VERIFY_XV6_TIMEOUT:-5m}" "$ROOT/scripts/run_xv6_smoke.sh"
else
  echo "[verify] xv6 smoke skipped (set RUN_XV6=1, XV6_KERNEL, XV6_FS_IMG)"
fi

echo "[verify] all checks passed"
