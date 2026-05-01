#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROGRAM_DIR="$ROOT/tests/programs"
: "${SIM_BIN:="$ROOT/build/pipeline_core_program/obj_dir/Vpipeline_core"}"
: "${TEST_COMPILE_TIMEOUT:=30s}"
: "${TEST_RUN_TIMEOUT:=30s}"
: "${SIM_CYCLE_LIMIT:=100000}"

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

echo "Starting C++ Program Tests"
echo "---------------------------------"

for cpp_file in "$PROGRAM_DIR"/*.cpp; do
  test_name="$(basename "$cpp_file")"
  elf_file="${cpp_file%.cpp}.elf"
  TOTAL=$((TOTAL + 1))

  printf "%-22s " "$test_name..."

  if ! run_with_timeout "$TEST_COMPILE_TIMEOUT" \
      "$ROOT/scripts/compile_program.sh" "$cpp_file" "$elf_file" >/dev/null; then
    echo -e "\033[0;31mCOMPILE FAILED\033[0m"
    FAILED=$((FAILED + 1))
    continue
  fi

  set +e
  OUT=$(run_with_timeout "$TEST_RUN_TIMEOUT" "$SIM_BIN" "$elf_file" "$SIM_CYCLE_LIMIT" 2>&1)
  EXIT_STATUS=$?
  set -e
  EXIT_VAL=$(echo "$OUT" | awk '/exit / { print $2; exit }')

  if [ "$EXIT_STATUS" -eq 0 ] && [ "$EXIT_VAL" = "0" ]; then
    echo -e "\033[0;32mPASSED\033[0m"
    PASSED=$((PASSED + 1))
  else
    echo -e "\033[0;31mFAILED\033[0m (exit ${EXIT_VAL:-none})"
    FAILED=$((FAILED + 1))
    echo "$OUT" | grep "diag" || true
  fi
done

echo "---------------------------------"
echo "Summary: $PASSED/$TOTAL passed ($FAILED failed)"

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
