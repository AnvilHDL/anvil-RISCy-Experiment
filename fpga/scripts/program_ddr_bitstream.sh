#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${DDR_BITSTREAM:="$ROOT/build/fpga/vivado-ddr/risky_genesys2_ddr.bit"}"
: "${HW_SERVER_URL:=localhost:3121}"

if ! command -v vivado >/dev/null 2>&1; then
  echo "[program-ddr] Vivado not found; source settings64.sh first" >&2
  exit 1
fi
if [ ! -r "$DDR_BITSTREAM" ]; then
  echo "[program-ddr] bitstream not found: $DDR_BITSTREAM" >&2
  exit 1
fi

vivado -mode batch -notrace \
  -source "$ROOT/fpga/scripts/program_bram_genesys2.tcl" \
  -tclargs "$DDR_BITSTREAM" "$HW_SERVER_URL"
