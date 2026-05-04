#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${FPGA_LINT_TIMEOUT:=3m}"
: "${FPGA_FILELIST:="$ROOT/build/fpga/risky_genesys2.f"}"

run_with_timeout() {
  local limit="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$limit" "$@"
  else
    "$@"
  fi
}

if [ ! -f "$FPGA_FILELIST" ]; then
  "$ROOT/scripts/export_fpga_rtl.sh" >/dev/null
fi

if ! command -v verilator >/dev/null 2>&1; then
  echo "[fpga-lint] verilator not found" >&2
  exit 1
fi

mapfile -t rtl_files < "$FPGA_FILELIST"
if [ "${#rtl_files[@]}" -eq 0 ]; then
  echo "[fpga-lint] empty FPGA filelist: $FPGA_FILELIST" >&2
  exit 1
fi

run_with_timeout "$FPGA_LINT_TIMEOUT" \
  verilator --lint-only -Wno-fatal --top risky_genesys2_top "${rtl_files[@]}"
