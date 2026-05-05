#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${FPGA_LINT_TIMEOUT:=3m}"
FILELIST="$ROOT/build/fpga/risky_genesys2_bram.f"

run_with_timeout() {
  local limit="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$limit" "$@"
  else
    "$@"
  fi
}

"$ROOT/scripts/export_fpga_bram_rtl.sh" >/dev/null

if ! command -v verilator >/dev/null 2>&1; then
  echo "[fpga-bram-lint] verilator not found" >&2
  exit 1
fi

mapfile -t rtl_files < "$FILELIST"
if [ "${#rtl_files[@]}" -eq 0 ]; then
  echo "[fpga-bram-lint] empty FPGA BRAM filelist: $FILELIST" >&2
  exit 1
fi

run_with_timeout "$FPGA_LINT_TIMEOUT" \
  verilator --lint-only -Wno-fatal --top risky_genesys2_bram_top "${rtl_files[@]}"
