#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${XV6_KERNEL:?set XV6_KERNEL to the xv6-riscv kernel ELF path}"
: "${XV6_FS_IMG:?set XV6_FS_IMG to the xv6-riscv fs.img path}"
: "${SIM_BIN:="$ROOT/build/pipeline_core_program/obj_dir/Vpipeline_core"}"
: "${XV6_CYCLE_LIMIT:=30000000}"
: "${XV6_HOST_TIMEOUT:=180s}"
: "${XV6_BOOT_LOG:="$ROOT/build/xv6_smoke.log"}"

run_with_timeout() {
  local limit="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$limit" "$@"
  else
    "$@"
  fi
}

if [ ! -r "$XV6_KERNEL" ]; then
  echo "[xv6] kernel not readable: $XV6_KERNEL" >&2
  exit 1
fi
if [ ! -r "$XV6_FS_IMG" ]; then
  echo "[xv6] fs image not readable: $XV6_FS_IMG" >&2
  exit 1
fi
if [ ! -x "$SIM_BIN" ]; then
  SIM_BIN="$("$ROOT/scripts/build_program_sim.sh")"
fi

mkdir -p "$(dirname "$XV6_BOOT_LOG")"
rm -f "$XV6_BOOT_LOG"
touch "$XV6_BOOT_LOG"

run_with_timeout "$XV6_HOST_TIMEOUT" \
  "$SIM_BIN" "$XV6_KERNEL" "$XV6_CYCLE_LIMIT" --disk "$XV6_FS_IMG" \
  >"$XV6_BOOT_LOG" 2>&1 &
sim_pid=$!

while kill -0 "$sim_pid" 2>/dev/null; do
  if grep -q 'xv6 kernel is booting' "$XV6_BOOT_LOG" && grep -q '^\$' "$XV6_BOOT_LOG"; then
    kill "$sim_pid" 2>/dev/null || true
    wait "$sim_pid" 2>/dev/null || true
    echo "[xv6] boot reached shell prompt"
    exit 0
  fi
  sleep 1
done

set +e
wait "$sim_pid"
status=$?
set -e

if grep -q 'xv6 kernel is booting' "$XV6_BOOT_LOG" && grep -q '^\$' "$XV6_BOOT_LOG"; then
  echo "[xv6] boot reached shell prompt"
  exit 0
fi

if [ "$status" -ne 0 ]; then
  echo "[xv6] simulator exited with status $status" >&2
  tail -80 "$XV6_BOOT_LOG" >&2 || true
  exit "$status"
fi

echo "[xv6] shell prompt not observed" >&2
tail -120 "$XV6_BOOT_LOG" >&2 || true
exit 1
