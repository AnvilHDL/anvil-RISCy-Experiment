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
UART_RX_SRC="$ROOT/fpga/src/risky_uart_rx.sv"
UART_RX_OUT="$FPGA_OUT_DIR/risky_uart_rx.sv"
PLIC_SRC="$ROOT/fpga/src/risky_plic.sv"
PLIC_OUT="$FPGA_OUT_DIR/risky_plic.sv"
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
if [ ! -r "$PERIPH_SRC" ] || [ ! -r "$UART_TX_SRC" ] || [ ! -r "$UART_RX_SRC" ] || [ ! -r "$PLIC_SRC" ]; then
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
import re

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()

required = [
    "module pipeline_core (",
    "input logic[0:0] rst_ni",
    "logic[31:0] imem_rdata_q_q;",
    "logic[63:0] mem_rdata_q_q;",
    "logic[63:0] ext_mip_q_q;",
    "logic[0:0] sv39_stall_q_q;",
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
    "  input logic[63:0] ext_mip_i,\n"
    "  input logic[31:0] imem_rdata_i,\n"
    "  input logic[63:0] mem_rdata_i,\n"
    "  input logic[0:0] sv39_stall_i,\n"
    "  input logic[0:0] sv39_if_valid_i,\n"
    "  input logic[63:0] sv39_if_pa_i,\n"
    "  input logic[0:0] sv39_if_pf_i,\n"
    "  input logic[0:0] sv39_mem_valid_i,\n"
    "  input logic[63:0] sv39_mem_pa_i,\n"
    "  input logic[0:0] sv39_mem_pf_i,\n"
    "  input logic[0:0] sv39_mem_pf_store_i,\n"
    "  output logic[63:0] pc_o,\n"
    "  output logic[63:0] mem_addr_o,\n"
    "  output logic[0:0] mem_read_o,\n"
    "  output logic[0:0] mem_write_o,\n"
    "  output logic[0:0] mem_store_valid_o,\n"
    "  output logic[63:0] mem_store_addr_o,\n"
    "  output logic[63:0] mem_store_word_o,\n"
    "  output logic[0:0] sim_exit_valid_o,\n"
    "  output logic[63:0] sim_exit_code_o,\n"
    "  output logic[1:0] priv_o,\n"
    "  output logic[63:0] satp_o,\n"
    "  output logic[0:0] sv39_flush_o,\n"
    "  output logic[63:0] mtime_o,\n"
    "  output logic[63:0] mtimecmp_o,\n"
    "  output logic[63:0] stimecmp_o\n"
    ");",
    1,
)
text, n = re.subn(r"assign (\S+) = imem_rdata_q_q;", r"assign \1 = imem_rdata_i;", text, count=1)
if n != 1:
    raise SystemExit("[fpga-bram] failed to patch imem_rdata_q_q feed")
text, n = re.subn(r"assign (\S+) = mem_rdata_q_q;", r"assign \1 = mem_rdata_i;", text, count=1)
if n != 1:
    raise SystemExit("[fpga-bram] failed to patch mem_rdata_q_q feed")

exact_replacements = {
    "localparam logic[63:0] thread_0_wire$5 = 64'd0;": "wire [63:0] thread_0_wire$5 = ext_mip_i;",
    "localparam logic[0:0] thread_0_wire$25 = 1'b0;": "wire thread_0_wire$25 = sv39_stall_i;",
    "localparam logic[0:0] thread_0_wire$26 = 1'b0;": "wire thread_0_wire$26 = sv39_if_valid_i;",
    "localparam logic[63:0] thread_0_wire$27 = 64'd0;": "wire [63:0] thread_0_wire$27 = sv39_if_pa_i;",
    "localparam logic[0:0] thread_0_wire$28 = 1'b0;": "wire thread_0_wire$28 = sv39_if_pf_i;",
    "localparam logic[0:0] thread_0_wire$29 = 1'b0;": "wire thread_0_wire$29 = sv39_mem_valid_i;",
    "localparam logic[63:0] thread_0_wire$30 = 64'd0;": "wire [63:0] thread_0_wire$30 = sv39_mem_pa_i;",
    "localparam logic[0:0] thread_0_wire$31 = 1'b0;": "wire thread_0_wire$31 = sv39_mem_pf_i;",
    "localparam logic[0:0] thread_0_wire$32 = 1'b0;": "wire thread_0_wire$32 = sv39_mem_pf_store_i;",
}
for before, after in exact_replacements.items():
    if before not in text:
        raise SystemExit("[fpga-bram] generated RTL shape changed; missing " + before)
    text = text.replace(before, after, 1)

text = text.replace(
    "endmodule",
    "  assign pc_o = pc_q_q;\n"
    "  assign mem_addr_o = ex_alu_result_q_q;\n"
    "  assign mem_read_o = ex_mem_read_obs_q_q;\n"
    "  assign mem_write_o = ex_mem_write_obs_q_q;\n"
    "  assign mem_store_valid_o = mem_store_valid_q_q;\n"
    "  assign mem_store_addr_o = mem_store_addr_q_q;\n"
    "  assign mem_store_word_o = mem_store_word_q_q;\n"
    "  assign sim_exit_valid_o = sim_exit_valid_q_q;\n"
    "  assign sim_exit_code_o = sim_exit_code_q_q;\n"
    "  assign priv_o = priv_q_q;\n"
    "  assign satp_o = satp_q_q;\n"
    "  assign sv39_flush_o = sv39_flush_q_q;\n"
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
cp "$UART_RX_SRC" "$UART_RX_OUT"
cp "$PLIC_SRC" "$PLIC_OUT"
python3 "$ROOT/scripts/gen_fpga_bram_init.py" \
  "$BRAM_INIT_SRC" "$ROOT/sim/link.ld" "$BRAM_INIT_OUT"

{
  echo "$BRAM_WRAPPER_OUT"
  echo "$PERIPH_OUT"
  echo "$UART_TX_OUT"
  echo "$UART_RX_OUT"
  echo "$PLIC_OUT"
  echo "$PATCHED_CORE"
} > "$FILELIST"

echo "[fpga-bram] wrote filelist $FILELIST"
echo "$FILELIST"
