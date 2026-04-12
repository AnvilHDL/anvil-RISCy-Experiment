#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="$ROOT/tests/unit"
INTEG_DIR="$ROOT/tests/integration"

eval "$(opam env --switch=/home/omar/anvil-exp-5.2 --set-switch)"
ANVIL_BIN="${ANVIL_BIN:-/home/omar/NUS/Anvil-Experimental/_build/default/bin/main.exe}"
if [ ! -x "$ANVIL_BIN" ]; then
  ANVIL_BIN="anvil"
fi

pass=0
total=0

for t in "$UNIT_DIR"/should_pass/*.anvil; do
  [ -e "$t" ] || continue
  total=$((total + 1))
  if "$ANVIL_BIN" -just-check "$t" > /dev/null; then
    echo "[PASS] unit/should_pass/$(basename "$t")"
    pass=$((pass + 1))
  else
    echo "[FAIL] unit/should_pass/$(basename "$t")"
  fi
done

for t in "$UNIT_DIR"/should_fail/*.anvil; do
  [ -e "$t" ] || continue
  total=$((total + 1))
  if ! "$ANVIL_BIN" -just-check "$t" > /dev/null; then
    echo "[PASS] unit/should_fail/$(basename "$t")"
    pass=$((pass + 1))
  else
    echo "[FAIL] unit/should_fail/$(basename "$t")"
  fi
done

for t in "$INTEG_DIR"/*.anvil; do
  [ -e "$t" ] || continue
  total=$((total + 1))
  stem="$(basename "${t%.anvil}")"
  if [ "$stem" = "mret_step_smoke" ]; then
    echo "[SKIP] integration/$stem (kept out of the default sweep while the full-core import path is still expensive)"
    total=$((total - 1))
    continue
  fi
  expected="$INTEG_DIR/$stem.test"
  sim_timeout=200
  if [ "$stem" = "pipeline_core" ]; then
    sim_timeout=100000
  fi
  bin="$("$ROOT/scripts/build.sh" "$t" "$stem")"
  output="$(mktemp)"
  if "$bin" "$sim_timeout" | grep -v 'Verilog \$finish' > "$output" && diff "$output" "$expected" > /dev/null; then
    echo "[PASS] integration/$stem"
    pass=$((pass + 1))
  else
    echo "[FAIL] integration/$stem"
    echo "expected vs actual for $stem:" >&2
    diff -u "$expected" "$output" || true
  fi
  rm -f "$output"
done

echo "[SUMMARY] $pass/$total passed"
test "$pass" -eq "$total"
