#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${BRAM_BITSTREAM:="$ROOT/build/fpga/vivado-bram/risky_genesys2_bram.bit"}"
: "${HW_SERVER_URL:=localhost:3121}"

if ! command -v vivado >/dev/null 2>&1; then
  echo "[program-bram] Vivado not found; source settings64.sh first" >&2
  exit 1
fi
if [ ! -r "$BRAM_BITSTREAM" ]; then
  echo "[program-bram] bitstream not found: $BRAM_BITSTREAM" >&2
  exit 1
fi

vivado -mode batch -notrace \
  -source "$ROOT/fpga/scripts/program_bram_genesys2.tcl" \
  -tclargs "$BRAM_BITSTREAM" "$HW_SERVER_URL"
