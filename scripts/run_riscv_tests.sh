#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISA_DIR="$ROOT/tests/isa"
SIM_BIN="$ROOT/build/pipeline_core/obj_dir/Vpipeline_core"

if [ ! -x "$SIM_BIN" ]; then
  echo "Error: simulation binary not found at $SIM_BIN"
  exit 1
fi

PASSED=0
FAILED=0
TOTAL=0

echo "Starting RISC-V ISA Tests (rv64ui)"
echo "---------------------------------"

for s_file in "$ISA_DIR"/*.S; do
  t_name=$(basename "${s_file%.S}")
  elf_file="$ISA_DIR/$t_name.elf"
  TOTAL=$((TOTAL + 1))
  
  printf "%-15s " "$t_name..."
  
  # Compile
  if ! clang++ \
    --target=riscv64-unknown-elf \
    -fuse-ld=lld \
    -march=rv64im_zicsr \
    -mabi=lp64 \
    -nostdlib \
    -ffreestanding \
    -fno-exceptions \
    -fno-rtti \
    -Wl,-T,"$ROOT/sim/link.ld" \
    -I "$ISA_DIR/env" -I "$ISA_DIR/macros/scalar" \
    "$ROOT/sim/startup.S" "$s_file" -o "$elf_file" 2>/dev/null; then
    echo -e "\033[0;31mCOMPILE FAILED\033[0m"
    FAILED=$((FAILED + 1))
    continue
  fi
  
  # Run
  OUT=$("$SIM_BIN" "$elf_file" 100000 2>&1)
  EXIT_STATUS=$?
  EXIT_VAL=$(echo "$OUT" | grep "exit " | awk '{print $2}')
  
  if [ "$EXIT_STATUS" -eq 0 ] && [ "$EXIT_VAL" == "0" ]; then
    echo -e "\033[0;32mPASSED\033[0m"
    PASSED=$((PASSED + 1))
  else
    echo -e "\033[0;31mFAILED\033[0m (exit $EXIT_VAL)"
    FAILED=$((FAILED + 1))
    # Show diagnostics if failed
    echo "$OUT" | grep "diag" || true
  fi
done

echo "---------------------------------"
echo "Summary: $PASSED/$TOTAL passed ($FAILED failed)"
