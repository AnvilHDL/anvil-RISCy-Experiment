#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

rm -rf "$ROOT/build/pipeline_core_program"

BUILD_NAME="pipeline_core_program" SIM_MAIN="$ROOT/sim/sim_main.cpp" "$ROOT/scripts/build.sh" \
  "$ROOT/src/core/top/pipeline_core.anvil" pipeline_core
