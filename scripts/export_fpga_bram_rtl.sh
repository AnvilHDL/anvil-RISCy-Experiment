#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${FPGA_OUT_DIR:="$ROOT/build/fpga/rtl"}"
CORE_SRC="$FPGA_OUT_DIR/pipeline_core.sv"
PATCHED_CORE="$FPGA_OUT_DIR/pipeline_core_bram_if.sv"
BRAM_WRAPPER_SRC="$ROOT/fpga/src/risky_genesys2_bram_top.sv"
BRAM_WRAPPER_OUT="$FPGA_OUT_DIR/risky_genesys2_bram_top.sv"
PERIPH_SRC="$ROOT/fpga/src/risky_fpga_peripherals.sv"
PERIPH_OUT="$FPGA_OUT_DIR/risky_fpga_peripherals.sv"
UART_TX_SRC="$ROOT/fpga/src/risky_uart_tx.sv"
UART_TX_OUT="$FPGA_OUT_DIR/risky_uart_tx.sv"
BRAM_INIT_SRC="$ROOT/fpga/programs/bringup_bram.S"
BRAM_INIT_OUT="$FPGA_OUT_DIR/risky_genesys2_bram_init.vh"
FILELIST="$ROOT/build/fpga/risky_genesys2_bram.f"

"$ROOT/scripts/export_fpga_rtl.sh" >/dev/null

if [ ! -r "$CORE_SRC" ]; then
  echo "[fpga-bram] missing generated core: $CORE_SRC" >&2
  exit 1
fi
if [ ! -r "$BRAM_WRAPPER_SRC" ]; then
  echo "[fpga-bram] missing BRAM wrapper: $BRAM_WRAPPER_SRC" >&2
  exit 1
fi
if [ ! -r "$PERIPH_SRC" ] || [ ! -r "$UART_TX_SRC" ]; then
  echo "[fpga-bram] missing FPGA peripheral sources" >&2
  exit 1
fi
if [ ! -r "$BRAM_INIT_SRC" ]; then
  echo "[fpga-bram] missing BRAM bring-up program source: $BRAM_INIT_SRC" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[fpga-bram] python3 not found" >&2
  exit 1
fi

python3 - "$CORE_SRC" "$PATCHED_CORE" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()

required = [
    "module pipeline_core (",
    "input logic[0:0] rst_ni",
    "assign thread_0_wire$6289 = imem_rdata_q_q;",
    "assign thread_0_wire$465 = mem_rdata_q_q;",
    "endmodule",
]
missing = [pattern for pattern in required if pattern not in text]
if missing:
    raise SystemExit("[fpga-bram] generated RTL shape changed; missing " + ", ".join(missing))

text = text.replace(
    "module pipeline_core (\n"
    "  input logic[0:0] clk_i,\n"
    "  input logic[0:0] rst_ni\n"
    ");",
    "module pipeline_core_bram_if (\n"
    "  input logic[0:0] clk_i,\n"
    "  input logic[0:0] rst_ni,\n"
    "  input logic[31:0] imem_rdata_i,\n"
    "  input logic[63:0] mem_rdata_i,\n"
    "  output logic[63:0] pc_o,\n"
    "  output logic[63:0] mem_addr_o,\n"
    "  output logic[0:0] mem_store_valid_o,\n"
    "  output logic[63:0] mem_store_addr_o,\n"
    "  output logic[63:0] mem_store_word_o,\n"
    "  output logic[0:0] sim_exit_valid_o,\n"
    "  output logic[63:0] sim_exit_code_o,\n"
    "  output logic[63:0] mtime_o,\n"
    "  output logic[63:0] mtimecmp_o,\n"
    "  output logic[63:0] stimecmp_o\n"
    ");",
    1,
)
text = text.replace("assign thread_0_wire$6289 = imem_rdata_q_q;", "assign thread_0_wire$6289 = imem_rdata_i;")
text = text.replace("assign thread_0_wire$465 = mem_rdata_q_q;", "assign thread_0_wire$465 = mem_rdata_i;")
text = text.replace(
    "endmodule",
    "  assign pc_o = pc_q_q;\n"
    "  assign mem_addr_o = ex_alu_result_q_q;\n"
    "  assign mem_store_valid_o = mem_store_valid_q_q;\n"
    "  assign mem_store_addr_o = mem_store_addr_q_q;\n"
    "  assign mem_store_word_o = mem_store_word_q_q;\n"
    "  assign sim_exit_valid_o = sim_exit_valid_q_q;\n"
    "  assign sim_exit_code_o = sim_exit_code_q_q;\n"
    "  assign mtime_o = mtime_q_q;\n"
    "  assign mtimecmp_o = mtimecmp_q_q;\n"
    "  assign stimecmp_o = stimecmp_q_q;\n"
    "endmodule",
    1,
)

open(dst, "w", encoding="utf-8").write(text)
PY

if ! rg -q "= imem_rdata_i;" "$PATCHED_CORE"; then
  echo "[fpga-bram] FATAL: imem_rdata_i patch not applied" >&2
  exit 1
fi
if ! rg -q "= mem_rdata_i;" "$PATCHED_CORE"; then
  echo "[fpga-bram] FATAL: mem_rdata_i patch not applied" >&2
  exit 1
fi

cp "$BRAM_WRAPPER_SRC" "$BRAM_WRAPPER_OUT"
cp "$PERIPH_SRC" "$PERIPH_OUT"
cp "$UART_TX_SRC" "$UART_TX_OUT"
python3 "$ROOT/scripts/gen_fpga_bram_init.py" \
  "$BRAM_INIT_SRC" "$ROOT/sim/link.ld" "$BRAM_INIT_OUT"

{
  echo "$BRAM_WRAPPER_OUT"
  echo "$PERIPH_OUT"
  echo "$UART_TX_OUT"
  echo "$PATCHED_CORE"
} > "$FILELIST"

echo "[fpga-bram] wrote filelist $FILELIST"
echo "$FILELIST"
