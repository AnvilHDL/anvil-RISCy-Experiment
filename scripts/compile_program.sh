#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <program.cpp> [output.elf]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$1"
OUT="${2:-${SRC%.cpp}.elf}"

COMMON_FLAGS=(
  -march=rv64im_zicsr
  -mabi=lp64
  -mcmodel=medany
  -nostdlib
  -O1
  -ffreestanding
  -fno-exceptions
  -fno-rtti
)

if command -v riscv64-unknown-elf-g++ >/dev/null 2>&1; then
  riscv64-unknown-elf-g++ \
    "${COMMON_FLAGS[@]}" \
    -T "$ROOT/sim/link.ld" \
    "$ROOT/sim/startup.S" "$SRC" -o "$OUT"
else
  clang++ \
    --target=riscv64-unknown-elf \
    -fuse-ld=lld \
    "${COMMON_FLAGS[@]}" \
    -Wl,-T,"$ROOT/sim/link.ld" \
    "$ROOT/sim/startup.S" "$SRC" -o "$OUT"
fi
