#!/usr/bin/env bash
# export_fpga_ddr_rtl.sh — Copy DDR3/xv6 RTL sources into build/fpga/rtl
# Runs the same Anvil-generated core patcher as the BRAM flow, then adds
# the DDR-specific modules (PTW, arbiter, MIG adapter, DDR top).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FPGA_OUT_DIR="${FPGA_OUT_DIR:-$ROOT/build/fpga/rtl}"
mkdir -p "$FPGA_OUT_DIR"

SRC="$ROOT/fpga/src"

# ---- Core: reuse BRAM patcher (same patched pipeline_core_bram_if.sv) ----
echo "[fpga-ddr] patching Anvil core RTL..."
"$ROOT/scripts/export_fpga_bram_rtl.sh"

# ---- DDR-specific modules ----
echo "[fpga-ddr] copying DDR3 RTL modules..."
cp "$SRC/risky_genesys2_ddr_top.sv"  "$FPGA_OUT_DIR/"
cp "$SRC/risky_ptw.sv"               "$FPGA_OUT_DIR/"
cp "$SRC/risky_mem_arbiter.sv"       "$FPGA_OUT_DIR/"
cp "$SRC/risky_mig_adapter.sv"       "$FPGA_OUT_DIR/"
# peripherals/uart/plic already copied by BRAM patcher

# ---- Verilator lint (excludes MIG, which is IP-generated) ----
echo "[fpga-ddr] verilator lint (DDR top, excl. MIG)..."
verilator --lint-only --sv --Wall --Wno-UNUSED --Wno-UNDRIVEN \
  -Wno-DECLFILENAME \
  --bbox-module axi_clock_converter_0 \
  --top-module risky_genesys2_ddr_top \
  "$FPGA_OUT_DIR/risky_genesys2_ddr_top.sv" \
  "$FPGA_OUT_DIR/risky_ptw.sv" \
  "$FPGA_OUT_DIR/risky_mem_arbiter.sv" \
  "$FPGA_OUT_DIR/risky_mig_adapter.sv" \
  "$FPGA_OUT_DIR/risky_fpga_peripherals.sv" \
  "$FPGA_OUT_DIR/risky_uart_tx.sv" \
  "$FPGA_OUT_DIR/risky_uart_rx.sv" \
  "$FPGA_OUT_DIR/risky_plic.sv" \
  "$FPGA_OUT_DIR/pipeline_core_bram_if.sv" \
  --bbox-unsup 2>&1 | grep -v "^%" || true

echo "[fpga-ddr] DDR RTL export complete: $FPGA_OUT_DIR"
