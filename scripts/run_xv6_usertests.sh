#!/usr/bin/env bash
# Run xv6-riscv usertests in simulation and report pass/fail.
#
# Usage:
#   XV6_KERNEL=/path/to/kernel XV6_FS_IMG=/path/to/fs.img \
#     scripts/run_xv6_usertests.sh
#
# The simulator must already be built (scripts/build_program_sim.sh).
# usertests is computationally heavy — run this on castle, not locally.
#
# Key tunable vars:
#   XV6_USERTESTS_CYCLES   — cycle budget (default 500000000 = 500M)
#   XV6_USERTESTS_TIMEOUT  — wall-clock limit (default 3600s = 1 hour)
#   XV6_USERTESTS_LOG      — path to capture full sim output

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

: "${XV6_KERNEL:?set XV6_KERNEL to the xv6-riscv kernel ELF path}"
: "${XV6_FS_IMG:?set XV6_FS_IMG to the xv6-riscv fs.img path}"
: "${SIM_BIN:="$ROOT/build/pipeline_core_program/obj_dir/Vpipeline_core"}"
: "${XV6_USERTESTS_CYCLES:=500000000}"
: "${XV6_USERTESTS_TIMEOUT:=3600s}"
: "${XV6_USERTESTS_LOG:="$ROOT/build/xv6_usertests.log"}"

if [ ! -r "$XV6_KERNEL" ]; then
  echo "[usertests] kernel not readable: $XV6_KERNEL" >&2
  exit 1
fi
if [ ! -r "$XV6_FS_IMG" ]; then
  echo "[usertests] fs image not readable: $XV6_FS_IMG" >&2
  exit 1
fi
if [ ! -x "$SIM_BIN" ]; then
  echo "[usertests] simulator binary not found: $SIM_BIN" >&2
  echo "[usertests] run scripts/build_program_sim.sh first" >&2
  exit 1
fi

run_with_timeout() {
  local limit="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$limit" "$@"
  else
    "$@"
  fi
}

mkdir -p "$(dirname "$XV6_USERTESTS_LOG")"
rm -f "$XV6_USERTESTS_LOG"
touch "$XV6_USERTESTS_LOG"

echo "[usertests] starting — cycles=$XV6_USERTESTS_CYCLES timeout=$XV6_USERTESTS_TIMEOUT"
echo "[usertests] log: $XV6_USERTESTS_LOG"

sim_pid=""
cleanup() {
  if [ -n "$sim_pid" ] && kill -0 "$sim_pid" 2>/dev/null; then
    kill "$sim_pid" 2>/dev/null || true
    wait "$sim_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

run_with_timeout "$XV6_USERTESTS_TIMEOUT" \
  "$SIM_BIN" "$XV6_KERNEL" "$XV6_USERTESTS_CYCLES" \
    --disk "$XV6_FS_IMG" \
    --run-cmd "usertests" \
    --pass-pat "ALL TESTS PASSED" \
    --fail-pat "SOME TESTS FAILED" \
  >"$XV6_USERTESTS_LOG" 2>&1 &
sim_pid=$!

# Poll every 10 seconds and print a heartbeat so CI logs show progress.
while kill -0 "$sim_pid" 2>/dev/null; do
  sleep 10
  if grep -q 'ALL TESTS PASSED' "$XV6_USERTESTS_LOG" 2>/dev/null; then
    echo "[usertests] PASS — all tests passed"
    kill "$sim_pid" 2>/dev/null || true
    wait "$sim_pid" 2>/dev/null || true
    sim_pid=""
    exit 0
  fi
  if grep -q 'SOME TESTS FAILED' "$XV6_USERTESTS_LOG" 2>/dev/null; then
    echo "[usertests] FAIL — some tests failed" >&2
    tail -60 "$XV6_USERTESTS_LOG" >&2 || true
    kill "$sim_pid" 2>/dev/null || true
    wait "$sim_pid" 2>/dev/null || true
    sim_pid=""
    exit 1
  fi
  # Print a heartbeat line every poll to show CI we're alive.
  tail -1 "$XV6_USERTESTS_LOG" 2>/dev/null | \
    grep -o '\[HB tick=[0-9]*\]' | \
    sed 's/^/[usertests] /' || true
done

# Simulator exited on its own (pattern matched or cycle limit hit).
set +e
wait "$sim_pid"
status=$?
sim_pid=""
set -e

if grep -q 'ALL TESTS PASSED' "$XV6_USERTESTS_LOG" 2>/dev/null; then
  echo "[usertests] PASS — all tests passed"
  exit 0
fi
if grep -q 'SOME TESTS FAILED' "$XV6_USERTESTS_LOG" 2>/dev/null; then
  echo "[usertests] FAIL — some tests failed" >&2
  grep -n 'FAILED' "$XV6_USERTESTS_LOG" | tail -20 >&2 || true
  exit 1
fi

echo "[usertests] INCONCLUSIVE — cycle limit or timeout reached (status=$status)" >&2
tail -80 "$XV6_USERTESTS_LOG" >&2 || true
exit 2
