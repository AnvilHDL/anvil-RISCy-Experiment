#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <program.cpp|program.elf> [timeout] [extra-sim-args...]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT="$1"
shift
TIMEOUT="5000"
HOST_TIMEOUT="${HOST_TIMEOUT:-120s}"
if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
  TIMEOUT="$1"
  shift
fi

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
  "$ROOT/scripts/compile_program.sh" "$INPUT" "$ELF"
else
  ELF="$INPUT"
fi

BIN="$("$ROOT/scripts/build_program_sim.sh")"
run_with_timeout "$HOST_TIMEOUT" "$BIN" "$ELF" "$TIMEOUT" "$@"
