#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${FPGA_OUT_DIR:-$ROOT/build/fpga/rtl}"
SRC_FILE="${FPGA_ANVIL_SRC:-$ROOT/src/core/top/pipeline_core.anvil}"
TOP_MODULE="${FPGA_CORE_TOP:-pipeline_core}"
SV_FILE="$OUT_DIR/$TOP_MODULE.sv"
WRAPPER_SRC="$ROOT/fpga/src/risky_genesys2_top.sv"
WRAPPER_OUT="$OUT_DIR/risky_genesys2_top.sv"
FILELIST="$ROOT/build/fpga/risky_genesys2.f"

: "${ANVIL_BIN:=/home/omar/NUS/Anvil-Experimental/_build/default/bin/main.exe}"
: "${ANVIL_FLAGS:=-O 0 -disable-lt-checks}"
: "${ANVIL_VMEM_MB:=12288}"
: "${ANVIL_TIMEOUT:=20m}"

run_with_timeout() {
  local limit="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "$limit" "$@"
  else
    "$@"
  fi
}

if [ -f "$HOME/anvil-exp-5.2/.opam-switch/environment" ] || command -v opam >/dev/null 2>&1; then
  eval "$(opam env --switch=/home/omar/anvil-exp-5.2 --set-switch 2>/dev/null || true)"
fi

if [ ! -x "$ANVIL_BIN" ]; then
  ANVIL_BIN="anvil"
fi

if ! command -v "$ANVIL_BIN" >/dev/null 2>&1 && [ ! -x "$ANVIL_BIN" ]; then
  echo "[fpga-rtl] Anvil compiler not found: $ANVIL_BIN" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" "$(dirname "$FILELIST")"

echo "[fpga-rtl] generating $SV_FILE"
(
  echo 900 > /proc/self/oom_score_adj 2>/dev/null || true
  if [ "$ANVIL_VMEM_MB" -gt 0 ] 2>/dev/null; then
    ulimit -v $((ANVIL_VMEM_MB * 1024))
  fi
  run_with_timeout "$ANVIL_TIMEOUT" "$ANVIL_BIN" $ANVIL_FLAGS "$SRC_FILE"
) > "$SV_FILE"

cp "$WRAPPER_SRC" "$WRAPPER_OUT"

{
  echo "$WRAPPER_OUT"
  echo "$SV_FILE"
} > "$FILELIST"

echo "[fpga-rtl] wrote filelist $FILELIST"
echo "$FILELIST"
