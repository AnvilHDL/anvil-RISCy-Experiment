#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${LINT_TIMEOUT:=2m}"
: "${SV_FILE:="$ROOT/build/pipeline_core_program/pipeline_core.anvil.sv"}"

run_with_timeout() {
  local limit="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$limit" "$@"
  else
    "$@"
  fi
}

if [ ! -f "$SV_FILE" ]; then
  "$ROOT/scripts/build_program_sim.sh" >/dev/null
fi

if ! command -v verilator >/dev/null 2>&1; then
  echo "[lint] verilator not found" >&2
  exit 1
fi

run_with_timeout "$LINT_TIMEOUT" \
  verilator --lint-only -Wno-fatal --top pipeline_core "$SV_FILE"
