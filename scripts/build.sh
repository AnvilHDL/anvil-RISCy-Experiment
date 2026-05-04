#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <anvil-file> [top-module]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_FILE="$1"
TOP_MODULE="${2:-$(basename "${SRC_FILE%.anvil}")}"
BUILD_NAME="${BUILD_NAME:-$TOP_MODULE}"
BUILD_DIR="$ROOT/build/$BUILD_NAME"
OBJ_DIR="$BUILD_DIR/obj_dir"
SV_FILE="$BUILD_DIR/$TOP_MODULE.anvil.sv"
DRIVER_CPP="$BUILD_DIR/${TOP_MODULE}_driver.cpp"
if [ -n "${SIM_MAIN:-}" ]; then
  DRIVER_TEMPLATE="$SIM_MAIN"
elif [ -f "$ROOT/tests/sim_main.cpp" ]; then
  DRIVER_TEMPLATE="$ROOT/tests/sim_main.cpp"
else
  DRIVER_TEMPLATE="$ROOT/sim/sim_main.cpp"
fi

mkdir -p "$BUILD_DIR"

ANVIL_BIN="${ANVIL_BIN:-/home/omar/NUS/Anvil-Experimental/_build/default/bin/main.exe}"
ANVIL_FLAGS="${ANVIL_FLAGS:-}"
ANVIL_VMEM_MB="${ANVIL_VMEM_MB:-12288}"
ANVIL_TIMEOUT="${ANVIL_TIMEOUT:-20m}"
VERILATOR_TIMEOUT="${VERILATOR_TIMEOUT:-30m}"
MAKE_TIMEOUT="${MAKE_TIMEOUT:-30m}"

if [ -f "$HOME/anvil-exp-5.2/.opam-switch/environment" ] || command -v opam >/dev/null 2>&1; then
  eval "$(opam env --switch=/home/omar/anvil-exp-5.2 --set-switch 2>/dev/null || true)"
fi

if [ ! -x "$ANVIL_BIN" ]; then
  ANVIL_BIN="anvil"
fi

if [ ! -r "$SRC_FILE" ]; then
  echo "[build] Anvil source not readable: $SRC_FILE" >&2
  exit 1
fi
if [ ! -r "$DRIVER_TEMPLATE" ]; then
  echo "[build] simulator driver template not readable: $DRIVER_TEMPLATE" >&2
  exit 1
fi
if ! command -v "$ANVIL_BIN" >/dev/null 2>&1 && [ ! -x "$ANVIL_BIN" ]; then
  echo "[build] Anvil compiler not found: $ANVIL_BIN" >&2
  exit 1
fi
if ! command -v verilator >/dev/null 2>&1; then
  echo "[build] verilator not found" >&2
  exit 1
fi
if ! command -v make >/dev/null 2>&1; then
  echo "[build] make not found" >&2
  exit 1
fi

if [ -z "$ANVIL_FLAGS" ]; then
  case "$(basename "$SRC_FILE")" in
    pipeline_core.anvil|mret_step_smoke.anvil)
      ANVIL_FLAGS="-O 0 -disable-lt-checks"
      ;;
  esac
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

# Mark only the Anvil compiler as a high-priority OOM target so the kernel
# kills it before unrelated desktop/session processes if memory gets critical.
(
  echo 900 > /proc/self/oom_score_adj 2>/dev/null || true
  if [ "$ANVIL_VMEM_MB" -gt 0 ] 2>/dev/null; then
    ulimit -v $((ANVIL_VMEM_MB * 1024))
  fi
  read -r -a anvil_flags <<< "$ANVIL_FLAGS"
  run_with_timeout "$ANVIL_TIMEOUT" "$ANVIL_BIN" "${anvil_flags[@]}" "$SRC_FILE"
) > "$SV_FILE"
sed "s/Vtop/V${TOP_MODULE}/g" "$DRIVER_TEMPLATE" > "$DRIVER_CPP"

run_with_timeout "$VERILATOR_TIMEOUT" verilator --cc --exe --public-flat-rw --top "$TOP_MODULE" --Mdir "$OBJ_DIR" -j 1 "$SV_FILE" "$DRIVER_CPP" >&2
run_with_timeout "$MAKE_TIMEOUT" make -C "$OBJ_DIR" -f "V${TOP_MODULE}.mk" -j 1 OBJCACHE= >&2

echo "$OBJ_DIR/V$TOP_MODULE"
