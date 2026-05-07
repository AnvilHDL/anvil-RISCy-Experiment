#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${DDR_CALIB_BITSTREAM:="$ROOT/build/fpga/vivado-ddr-calib/risky_genesys2_ddr_calib.bit"}"

if ! command -v vivado >/dev/null 2>&1; then
  echo "[program-ddr-calib] Vivado not found; source settings64.sh first" >&2
  exit 1
fi
if [[ ! -f "$DDR_CALIB_BITSTREAM" ]]; then
  echo "[program-ddr-calib] bitstream not found: $DDR_CALIB_BITSTREAM" >&2
  exit 1
fi

vivado -mode batch -source "$ROOT/fpga/scripts/program_local_genesys2.tcl" -tclargs "$DDR_CALIB_BITSTREAM"
