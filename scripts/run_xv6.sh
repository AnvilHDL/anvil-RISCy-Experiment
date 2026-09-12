#!/usr/bin/env bash
# Boot xv6 on the core, from a clean checkout, in one command.
#
#   scripts/run_xv6.sh              boot until the shell prompt, then stop
#   scripts/run_xv6.sh -i           boot and stay attached for interactive use
#
# Steps performed, each skipped when already done:
#   1. check out the xv6 submodule
#   2. install a riscv64 bare-metal toolchain into .toolchain/
#   3. build xv6 for this core's ISA (out of tree; the submodule stays clean)
#   4. build the Verilator simulator from the Anvil sources
#   5. boot
#
# Simulation runs at roughly 200k cycles/s, and the boot needs on the order of
# 10^8 cycles, so expect several minutes. XV6_CYCLE_LIMIT bounds the run in
# simulated cycles and XV6_HOST_TIMEOUT in wall clock (0 disables it).
#
# ANVIL_BIN selects the Anvil compiler; it defaults to `anvil` on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${ANVIL_BIN:=anvil}"
: "${XV6_CYCLE_LIMIT:=2000000000}"
: "${XV6_HOST_TIMEOUT:=0}"
INTERACTIVE=0
[ "${1:-}" = "-i" ] && INTERACTIVE=1

# opam's sandbox needs the real bwrap; some SDKs ship a stub that always fails.
if [ -x /usr/bin/bwrap ]; then PATH="/usr/bin:$PATH"; fi

step() { printf '\n[run-xv6] %s\n' "$1" >&2; }

step "xv6 submodule"
if [ ! -f "$ROOT/third_party/xv6-riscv/Makefile" ]; then
  git -C "$ROOT" submodule update --init --depth 1 third_party/xv6-riscv
fi

step "riscv toolchain"
if [ ! -x "$ROOT/.toolchain/riscv/bin/riscv64-unknown-elf-gcc" ]; then
  "$ROOT/scripts/toolchain/install_riscv_toolchain.sh" >/dev/null
fi
PATH="$ROOT/.toolchain/riscv/bin:$PATH"
export PATH

step "anvil compiler"
if ! command -v "$ANVIL_BIN" >/dev/null 2>&1 && [ ! -x "$ANVIL_BIN" ]; then
  echo "[run-xv6] Anvil not found: $ANVIL_BIN" >&2
  echo "[run-xv6] build it, then re-run with ANVIL_BIN=/path/to/anvil" >&2
  exit 1
fi
export ANVIL_BIN

step "xv6 kernel and fs.img"
KERNEL="$ROOT/.toolchain/xv6-build/kernel/kernel"
FS_IMG="$ROOT/.toolchain/xv6-build/fs.img"
if [ ! -r "$KERNEL" ] || [ ! -r "$FS_IMG" ]; then
  "$ROOT/scripts/toolchain/build_xv6.sh" >/dev/null
fi

step "simulator"
SIM="$ROOT/build/pipeline_core_program/obj_dir/Vpipeline_core"
if [ ! -x "$SIM" ]; then
  "$ROOT/scripts/build_program_sim.sh" >/dev/null
fi

if [ "$INTERACTIVE" = "1" ]; then
  step "booting (interactive; Ctrl-C to stop)"
  exec "$SIM" "$KERNEL" "$XV6_CYCLE_LIMIT" --disk "$FS_IMG"
fi

step "booting (stops at the shell prompt; expect several minutes)"
LOG="$ROOT/build/xv6_smoke.log"
XV6_KERNEL="$KERNEL" XV6_FS_IMG="$FS_IMG" \
XV6_CYCLE_LIMIT="$XV6_CYCLE_LIMIT" XV6_HOST_TIMEOUT="$XV6_HOST_TIMEOUT" \
XV6_BOOT_LOG="$LOG" \
  "$ROOT/scripts/run_xv6_smoke.sh" &
smoke_pid=$!

# The smoke test logs to a file, so report elapsed time until it finishes.
started=$SECONDS
while kill -0 "$smoke_pid" 2>/dev/null; do
  sleep 15
  kill -0 "$smoke_pid" 2>/dev/null || break
  printf '[run-xv6] booting, %ds elapsed\n' "$((SECONDS - started))" >&2
done
wait "$smoke_pid"
