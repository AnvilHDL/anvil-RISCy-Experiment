#!/usr/bin/env bash
set -euo pipefail

fail=0

need_cmd() {
  local cmd="$1"
  local why="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '[fpga-check] found %-12s %s\n' "$cmd" "$(command -v "$cmd")"
  else
    printf '[fpga-check] missing %-10s %s\n' "$cmd" "$why" >&2
    fail=1
  fi
}

need_file() {
  local path="$1"
  local why="$2"
  if [ -e "$path" ]; then
    printf '[fpga-check] found %-12s %s\n' "$(basename "$path")" "$path"
  else
    printf '[fpga-check] missing %-10s %s\n' "$(basename "$path")" "$why" >&2
    fail=1
  fi
}

need_cmd vivado "required for Kintex-7 Genesys 2 synthesis/implementation"
need_cmd timeout "required so FPGA build steps cannot hang indefinitely"
need_cmd verilator "required for generated-SystemVerilog lint before Vivado"

need_file "../src/core/top/pipeline_core.anvil" "core source must exist"
need_file "constraints/genesys2.xdc" "Genesys 2 board constraints must exist"
need_file "src/risky_genesys2_top.sv" "FPGA wrapper must exist"

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'EOF'
[fpga-check] FAILED

Install Vivado with Kintex-7 support and source its settings64.sh file before
running synthesis.

Genesys 2 uses a Kintex-7 XC7K325T-2FFG900C device, which may require a
licensed Vivado installation rather than the free WebPACK flow.
EOF
  exit 1
fi

echo "[fpga-check] Genesys 2 prerequisites passed"
