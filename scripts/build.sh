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
DRIVER_TEMPLATE="${SIM_MAIN:-$ROOT/tests/sim_main.cpp}"

mkdir -p "$BUILD_DIR"

eval "$(opam env --switch=/home/omar/anvil-exp-5.2 --set-switch)"
ANVIL_BIN="${ANVIL_BIN:-/home/omar/NUS/Anvil-Experimental/_build/default/bin/main.exe}"
ANVIL_FLAGS="${ANVIL_FLAGS:-}"
if [ ! -x "$ANVIL_BIN" ]; then
  ANVIL_BIN="anvil"
fi

if [ -z "$ANVIL_FLAGS" ]; then
  case "$(basename "$SRC_FILE")" in
    pipeline_core.anvil|mret_step_smoke.anvil)
      ANVIL_FLAGS="-O 0 -disable-lt-checks"
      ;;
  esac
fi

"$ANVIL_BIN" $ANVIL_FLAGS "$SRC_FILE" > "$SV_FILE"
sed "s/Vtop/V${TOP_MODULE}/g" "$DRIVER_TEMPLATE" > "$DRIVER_CPP"

verilator --cc --exe --top "$TOP_MODULE" --Mdir "$OBJ_DIR" -j 1 "$SV_FILE" "$DRIVER_CPP" >&2
make -C "$OBJ_DIR" -f "V${TOP_MODULE}.mk" -j 1 OBJCACHE= >&2

echo "$OBJ_DIR/V$TOP_MODULE"
