#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${FPGA_BUILD_DIR:="$ROOT/build/fpga/vivado-bram"}"
: "${VIVADO_IMPL_TIMEOUT:=2h}"
: "${VIVADO_JOBS:=4}"

run_with_timeout() {
  local limit="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$limit" "$@"
  else
    "$@"
  fi
}

if ! command -v vivado >/dev/null 2>&1; then
  echo "[vivado-bram] Vivado not found; source settings64.sh first" >&2
  exit 1
fi

"$ROOT/scripts/export_fpga_bram_rtl.sh" >/dev/null
mkdir -p "$FPGA_BUILD_DIR"

run_with_timeout "$VIVADO_IMPL_TIMEOUT" vivado -mode batch -notrace \
  -source "$ROOT/fpga/scripts/vivado_bitstream_bram_genesys2.tcl" \
  -tclargs "$ROOT" "$FPGA_BUILD_DIR" "$VIVADO_JOBS"

echo "[vivado-bram] bitstream: $FPGA_BUILD_DIR/risky_genesys2_bram.bit"
