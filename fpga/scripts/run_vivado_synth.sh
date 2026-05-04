#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${FPGA_BUILD_DIR:="$ROOT/build/fpga/vivado"}"
: "${VIVADO_TIMEOUT:=45m}"
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
  echo "[vivado] Vivado not found; source settings64.sh first" >&2
  exit 1
fi

mkdir -p "$FPGA_BUILD_DIR"

run_with_timeout "$VIVADO_TIMEOUT" vivado -mode batch -notrace \
  -source "$ROOT/fpga/scripts/vivado_synth_genesys2.tcl" \
  -tclargs "$ROOT" "$FPGA_BUILD_DIR" "$VIVADO_JOBS"
