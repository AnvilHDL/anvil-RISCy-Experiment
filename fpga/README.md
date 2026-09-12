# Genesys 2 FPGA targets

This directory contains the board wrappers, constraints, Vivado scripts, and
Makefile targets for the Digilent Genesys 2
(`XC7K325T-2FFG900C`).

The available flows cover generated-core synthesis, BRAM software bring-up,
DDR integration, and DDR calibration. The board targets are still under
development; see [the work log](../docs/WORK_LOG.md) for the current hardware
boundary.

## Requirements

- Anvil in `PATH`, or `ANVIL_BIN` set to the compiler executable
- Verilator for generated-SystemVerilog lint
- Vivado with Kintex-7 support
- A connected Genesys 2 for programming targets

Source the Vivado or Vivado Lab `settings64.sh` file when its executable is
not already in `PATH`.

## Targets

Run these commands from the repository root:

```bash
make -C fpga help
make -C fpga check

# Generated core and synthesis check
make -C fpga rtl
make -C fpga synth

# BRAM bring-up
make -C fpga bram
make -C fpga bitstream-bram
make -C fpga program-bram

# DDR target
make -C fpga ddr
make -C fpga bitstream-ddr
make -C fpga program-ddr

# Standalone DDR calibration
make -C fpga bitstream-ddr-calib
make -C fpga program-ddr-calib
```

The export and lint scripts can also be called directly:

```bash
scripts/export_fpga_rtl.sh
scripts/lint_fpga_rtl.sh
scripts/export_fpga_bram_rtl.sh
scripts/lint_fpga_bram_rtl.sh
scripts/export_fpga_ddr_rtl.sh
scripts/lint_fpga_ddr_rtl.sh
```

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `ANVIL_BIN` | `anvil` | Anvil compiler executable |
| `ANVIL_VMEM_MB` | `12288` | Anvil virtual-memory limit |
| `ANVIL_TIMEOUT` | `20m` | Anvil wall-clock limit |
| `FPGA_OUT_DIR` | `build/fpga/rtl` | Generated RTL directory |
| `FPGA_BUILD_DIR` | target-specific directory under `build/fpga` | Vivado output directory |
| `VIVADO_TIMEOUT` | `45m` | Synthesis wall-clock limit |
| `VIVADO_IMPL_TIMEOUT` | `2h` or `4h` | Implementation wall-clock limit |
| `VIVADO_JOBS` | `4` | Vivado job count |
| `BRAM_BITSTREAM` | BRAM build output | BRAM bitstream to program |
| `DDR_BITSTREAM` | DDR build output | DDR bitstream to program |
| `HW_SERVER_URL` | `localhost:3121` | Vivado hardware-server address |
| `VIVADO_LAB_SETTINGS` | unset | Optional settings script used by `program-fpga` |

## BRAM bring-up

The BRAM wrapper connects `pipeline_core_bram_if` to local memory and an FPGA
peripheral block. The bundled program sends `BOOT\r\nB\r\nL=5A\r\n` at
115200 baud and writes `0x5a` to the GPIO window.

After programming:

- `led[0]` indicates reset release;
- `led[1]` is a heartbeat;
- `led[7:2]` show the low six bits of the last GPIO byte;
- the FT232R USB-UART port carries the serial output at 115200 8N1.

On Linux, identify the serial device under `/dev/serial/by-id/`. The FT232R
entry is the UART; the Digilent Adept entries are the programming interface.

The convenience programmer accepts an optional bitstream:

```bash
fpga/scripts/program-fpga
fpga/scripts/program-fpga path/to/design.bit
```

If `vivado_lab` is not in `PATH`, set `VIVADO_LAB_SETTINGS` to the
installed `settings64.sh` file.

## Remote build

A bitstream built on another machine can be copied to the host connected to the
board and selected explicitly:

```bash
BRAM_BITSTREAM=path/to/risky_genesys2_bram.bit make -C fpga program-bram
```
