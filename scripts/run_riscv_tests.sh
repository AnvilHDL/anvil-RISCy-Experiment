#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISA_DIR="$ROOT/tests/isa"
: "${SIM_BIN:="$ROOT/build/pipeline_core_program/obj_dir/Vpipeline_core"}"
: "${TEST_COMPILE_TIMEOUT:=30s}"
: "${TEST_RUN_TIMEOUT:=30s}"
: "${RISCV_MARCH:=rv64im}"
: "${RISCV_MABI:=lp64}"

if command -v riscv64-unknown-elf-g++ >/dev/null 2>&1; then
  TEST_CXX=(riscv64-unknown-elf-g++)
else
  TEST_CXX=(clang++ --target=riscv64-unknown-elf -fuse-ld=lld)
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

if [ ! -x "$SIM_BIN" ]; then
  SIM_BIN="$("$ROOT/scripts/build_program_sim.sh")"
fi

PASSED=0
FAILED=0
TOTAL=0

echo "Starting RISC-V ISA Tests"
echo "---------------------------------"

for s_file in "$ISA_DIR"/*.S; do
  t_name=$(basename "${s_file%.S}")
  elf_file="$ISA_DIR/$t_name.elf"
  TOTAL=$((TOTAL + 1))
  
  printf "%-15s " "$t_name..."
  
  # Compile
  if ! run_with_timeout "$TEST_COMPILE_TIMEOUT" "${TEST_CXX[@]}" \
    -march="$RISCV_MARCH" \
    -mabi="$RISCV_MABI" \
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
  OUT=$(run_with_timeout "$TEST_RUN_TIMEOUT" "$SIM_BIN" "$elf_file" 100000 2>&1)
  EXIT_STATUS=$?
  EXIT_VAL=$(echo "$OUT" | awk '/exit / { print $2; exit }')
  
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

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
