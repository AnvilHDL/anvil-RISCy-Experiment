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

: "${ANVIL_BIN:=anvil}"
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

if ! command -v "$ANVIL_BIN" >/dev/null 2>&1 && [ ! -x "$ANVIL_BIN" ]; then
  echo "[fpga-rtl] Anvil compiler not found: $ANVIL_BIN" >&2
  exit 1
fi
if [ ! -r "$SRC_FILE" ]; then
  echo "[fpga-rtl] Anvil source not readable: $SRC_FILE" >&2
  exit 1
fi
if [ ! -r "$WRAPPER_SRC" ]; then
  echo "[fpga-rtl] FPGA wrapper not readable: $WRAPPER_SRC" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" "$(dirname "$FILELIST")"

echo "[fpga-rtl] generating $SV_FILE"
(
  echo 900 > /proc/self/oom_score_adj 2>/dev/null || true
  if [ "$ANVIL_VMEM_MB" -gt 0 ] 2>/dev/null; then
    ulimit -v $((ANVIL_VMEM_MB * 1024))
  fi
  read -r -a anvil_flags <<< "$ANVIL_FLAGS"
  run_with_timeout "$ANVIL_TIMEOUT" "$ANVIL_BIN" "${anvil_flags[@]}" "$SRC_FILE"
) > "$SV_FILE"

cp "$WRAPPER_SRC" "$WRAPPER_OUT"

{
  echo "$WRAPPER_OUT"
  echo "$SV_FILE"
} > "$FILELIST"

echo "[fpga-rtl] wrote filelist $FILELIST"
echo "$FILELIST"
