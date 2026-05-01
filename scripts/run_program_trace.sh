#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <program.cpp|program.elf> [timeout]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT="$1"
TIMEOUT="${2:-100000}"
HOST_TIMEOUT="${HOST_TIMEOUT:-120s}"
BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT

run_with_timeout() {
  local limit="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$limit" "$@"
  else
    "$@"
  fi
}

if [[ "$INPUT" == *.cpp ]]; then
  ELF="${INPUT%.cpp}.elf"
  "$ROOT/scripts/compile_program.sh" "$INPUT" "$ELF" >/dev/null 2>"$BUILD_LOG" || {
    cat "$BUILD_LOG" >&2
    exit 1
  }
else
  ELF="$INPUT"
fi

BIN="$("$ROOT/scripts/build_program_sim.sh" 2>"$BUILD_LOG")" || {
  cat "$BUILD_LOG" >&2
  exit 1
}

run_with_timeout "$HOST_TIMEOUT" "$BIN" "$ELF" "$TIMEOUT" --trace 2> >(grep -v 'Verilog .*finish' >&2)
