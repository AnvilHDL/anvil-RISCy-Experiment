# Genesys 2 FPGA Bring-Up

This directory is the FPGA-facing bring-up area for RISCy-Experiment. It follows
the same broad shape used by CVA6-style FPGA targets: board constraints,
Vivado scripts, wrapper sources, and Makefile targets live under `fpga/`.

The selected board is the Digilent Genesys 2 with a Xilinx Kintex-7
`XC7K325T-2FFG900C`. CVA6/OpenHW also uses Genesys 2 as a FPGA development
platform, so this target keeps the repo layout familiar for future comparison.

## Current Target

The current FPGA target is a synthesis smoke wrapper:

- `fpga/src/risky_genesys2_top.sv`
- `fpga/constraints/genesys2.xdc`
- `fpga/scripts/vivado_synth_genesys2.tcl`

It packages the generated `pipeline_core` RTL behind Genesys 2 clock/reset,
LED, fan, and UART-idle pins. This proves the Anvil-generated processor can be
exported into a Vivado project without running Verilator.

This is not yet a full FPGA SoC capable of booting xv6 on the board. xv6 still
depends on simulation-backed RAM, Sv39 PTW, UART/PLIC/virtio, and disk behavior.

## Commands

From the repo root:

```bash
# Generate bounded Anvil RTL for FPGA use.
scripts/export_fpga_rtl.sh

# Lint the exported wrapper/core before opening Vivado.
scripts/lint_fpga_rtl.sh

# Check Genesys 2 prerequisites.
cd fpga && make check

# Run Vivado synthesis smoke when Vivado is installed/sourced.
cd fpga && make synth
```

Useful environment variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `ANVIL_VMEM_MB` | `12288` | Virtual-memory cap for Anvil generation |
| `ANVIL_TIMEOUT` | `20m` | Wall-clock limit for Anvil generation |
| `FPGA_OUT_DIR` | `build/fpga/rtl` | Generated RTL output directory |
| `FPGA_BUILD_DIR` | `build/fpga/vivado` | Vivado project/output directory |
| `VIVADO_TIMEOUT` | `45m` | Wall-clock limit for Vivado synthesis |
| `VIVADO_JOBS` | `4` | Vivado synthesis job count |

## Why This Is the First FPGA Step

The current simulation harness owns several services that real FPGA hardware
must eventually own. A small synthesis wrapper is still useful because it:

- verifies Anvil export without Verilator or host C++ dependencies,
- gives Vivado a real Genesys 2 part, top module, and constraints,
- keeps the FPGA flow bounded so failed builds terminate,
- creates a stable place to add RAM, UART, PLIC, and storage peripherals.

## Next Hardware Milestones

1. Add a real memory/MMIO request-response interface to `pipeline_core`.
2. Move RAM behind a synthesizable BRAM or AXI-attached memory subsystem.
3. Add UART and PLIC as RTL peripherals or bus-facing wrappers.
4. Move Sv39 PTW/TLB into RTL once memory reads use the common interface.
5. Choose the xv6 disk path: SD-card SPI, UART loader, debug bridge, or host
   bridge.
6. Run Vivado implementation and timing closure on Genesys 2.

## Toolchain Note

Genesys 2 uses a Kintex-7 part. Depending on Vivado version/licensing, this may
require a licensed Vivado installation rather than the free WebPACK flow. Source
Vivado before running `make synth`, for example:

```bash
source /tools/Xilinx/Vivado/<version>/settings64.sh
```
