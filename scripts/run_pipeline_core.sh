#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/pipeline_core/obj_dir/Vpipeline_core"

if [ ! -x "$BIN" ]; then
  echo "[INFO] pipeline_core binary not found; building it now" >&2
  "$ROOT/scripts/build.sh" "$ROOT/tests/integration/pipeline_core.anvil" pipeline_core >/dev/null
fi

echo "[RUN] pipeline_core"
"$BIN" 2000 2>&1 | grep -v 'Verilog \$finish'
