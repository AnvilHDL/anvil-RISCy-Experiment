#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <program.cpp|program.elf> [timeout]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT="$1"
TIMEOUT="${2:-100000}"
BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT

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

"$BIN" "$ELF" "$TIMEOUT" --trace 2> >(grep -v 'Verilog .*finish' >&2)
