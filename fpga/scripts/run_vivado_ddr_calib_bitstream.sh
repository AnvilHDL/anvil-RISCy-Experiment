#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${FPGA_BUILD_DIR:="$ROOT/build/fpga/vivado-ddr-calib"}"
: "${VIVADO_JOBS:=4}"

if ! command -v vivado >/dev/null 2>&1; then
  echo "[vivado-ddr-calib] Vivado not found; source settings64.sh first" >&2
  exit 1
fi

mkdir -p "$FPGA_BUILD_DIR"
vivado -mode batch \
  -source "$ROOT/fpga/scripts/vivado_bitstream_ddr_calib_genesys2.tcl" \
  -tclargs "$ROOT" "$FPGA_BUILD_DIR" "$VIVADO_JOBS"

echo "[vivado-ddr-calib] bitstream: $FPGA_BUILD_DIR/risky_genesys2_ddr_calib.bit"
