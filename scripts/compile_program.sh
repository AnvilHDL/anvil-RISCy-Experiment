#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <program.cpp> [output.elf]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$1"
OUT="${2:-${SRC%.cpp}.elf}"
: "${RISCV_MABI:=lp64}"

if command -v riscv64-unknown-elf-g++ >/dev/null 2>&1; then
  if [ -z "${RISCV_MARCH:-}" ]; then
    for candidate in rv64im_zicsr rv64im; do
      if printf 'int main() { return 0; }\n' | \
        riscv64-unknown-elf-g++ -x c++ -march="$candidate" -mabi="$RISCV_MABI" \
          -nostdlib -ffreestanding -fno-exceptions -fno-rtti -c -o /dev/null - \
          >/dev/null 2>&1; then
        RISCV_MARCH="$candidate"
        break
      fi
    done
    : "${RISCV_MARCH:=rv64im}"
  fi
  COMMON_FLAGS=(
    -march="$RISCV_MARCH"
    -mabi="$RISCV_MABI"
    -mcmodel=medany
    -nostdlib
    -O1
    -ffreestanding
    -fno-exceptions
    -fno-rtti
  )
  riscv64-unknown-elf-g++ \
    "${COMMON_FLAGS[@]}" \
    -T "$ROOT/sim/link.ld" \
    "$ROOT/sim/startup.S" "$SRC" -o "$OUT"
else
  : "${RISCV_MARCH:=rv64im_zicsr}"
  COMMON_FLAGS=(
    -march="$RISCV_MARCH"
    -mabi="$RISCV_MABI"
    -mcmodel=medany
    -nostdlib
    -O1
    -ffreestanding
    -fno-exceptions
    -fno-rtti
  )
  clang++ \
    --target=riscv64-unknown-elf \
    -fuse-ld=lld \
    "${COMMON_FLAGS[@]}" \
    -Wl,-T,"$ROOT/sim/link.ld" \
    "$ROOT/sim/startup.S" "$SRC" -o "$OUT"
fi
