# Genesys 2 FPGA Bring-Up

This directory is the FPGA-facing bring-up area for RISCy-Experiment. It follows
the same broad shape used by CVA6-style FPGA targets: board constraints,
Vivado scripts, wrapper sources, and Makefile targets live under `fpga/`.

The selected board is the Digilent Genesys 2 with a Xilinx Kintex-7
`XC7K325T-2FFG900C`. CVA6/OpenHW also uses Genesys 2 as a FPGA development
platform, so this target keeps the repo layout familiar for future comparison.

## Current Target

The current FPGA targets are:

- `fpga/src/risky_genesys2_top.sv`
- `fpga/src/risky_genesys2_bram_top.sv`
- `fpga/constraints/genesys2.xdc`
- `fpga/scripts/vivado_synth_genesys2.tcl`
- `fpga/scripts/vivado_bitstream_bram_genesys2.tcl`
- `fpga/scripts/program_bram_genesys2.tcl`

The smoke wrapper packages the generated `pipeline_core` RTL behind Genesys 2
clock/reset, LED, fan, and UART-idle pins. The BRAM wrapper packages a generated
`pipeline_core_bram_if` bridge with a small synthesizable memory and a separate
FPGA peripheral block for LED, UART, and CLINT readback. Both flows avoid large
Anvil memories so RTL export stays bounded.

This is not yet a full FPGA SoC capable of booting xv6 on the board. xv6 still
depends on simulation-backed RAM, Sv39 PTW, UART/PLIC/virtio, and disk behavior.

## Commands

From the repo root:

```bash
# Generate bounded Anvil RTL for FPGA use.
scripts/export_fpga_rtl.sh

# Lint the exported wrapper/core before opening Vivado.
scripts/lint_fpga_rtl.sh

# Export and lint the BRAM-backed bare-metal target.
scripts/lint_fpga_bram_rtl.sh

# Check Genesys 2 prerequisites.
cd fpga && make check

# Export/lint the BRAM-backed bare-metal target via Make.
cd fpga && make bram

# Implement the BRAM-backed target and write a .bit file.
cd fpga && make bitstream-bram

# Program a locally connected Genesys 2 board with that .bit file.
cd fpga && make program-bram

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
| `VIVADO_IMPL_TIMEOUT` | `2h` | Wall-clock limit for Vivado implementation/bitstream |
| `VIVADO_JOBS` | `4` | Vivado synthesis job count |
| `BRAM_BITSTREAM` | `build/fpga/vivado-bram/risky_genesys2_bram.bit` | Bitstream used by `make program-bram` |
| `HW_SERVER_URL` | `localhost:3121` | Vivado hardware-server URL for board programming |

## Server Build, Laptop Program Flow

If Vivado implementation runs on a remote server and the board is attached to a
laptop, build the bitstream on the server:

```bash
cd RISCy-Experiment
source /tools/Xilinx/Vivado/<version>/settings64.sh
cd fpga
make check
make bram
make bitstream-bram
```

Then copy `build/fpga/vivado-bram/risky_genesys2_bram.bit` to the laptop and
program the local board:

```bash
cd RISCy-Experiment
source /tools/Xilinx/Vivado/<version>/settings64.sh
cd fpga
BRAM_BITSTREAM=/path/to/risky_genesys2_bram.bit make program-bram
```

Expected first-board behavior for the BRAM target:

- `led[0]` turns on after reset is released.
- `led[1]` blinks as a heartbeat.
- `led[7:2]` show the lower six bits of the last GPIO byte written to
  `0x10000008`.
- the PROG/UART USB port emits software-authored UART text at 115200 baud.
- the bundled BRAM program writes `BOOT\r\nB\r\nL=5A\r\n` through the UART
  THR register at `0x10000000` and polls the UART LSR at `0x10000005`.
- the BRAM wrapper returns CLINT readback for `mtime` at `0x0200bff8` and
  `mtimecmp` at `0x02004000` using timer state already owned by the RTL core.

To watch the BRAM UART stream on the laptop attached to the board, open the
dedicated UART micro-USB port at 115200 8N1 before programming or pressing
reset. On Linux this is usually one of `/dev/ttyUSB0` or `/dev/ttyUSB1`;
identify the FT232 UART port with:

```bash
dmesg | tail -50
python3 -m serial.tools.miniterm /dev/ttyUSB0 115200
```

## Why This Is the First FPGA Step

The current simulation harness owns several services that real FPGA hardware
must eventually own. The smoke and BRAM wrappers are still useful because they:

- verifies Anvil export without Verilator or host C++ dependencies,
- gives Vivado a real Genesys 2 part, top module, and constraints,
- keeps the FPGA flow bounded so failed builds terminate,
- creates a stable place to add RAM, UART, PLIC, and storage peripherals,
- proves a tiny store-to-MMIO program can execute before the full xv6 SoC exists.

## Next Hardware Milestones

1. Add a real memory/MMIO request-response interface to `pipeline_core`.
2. Move RAM behind a synthesizable BRAM or AXI-attached memory subsystem.
3. Split the BRAM-side FPGA peripheral block into a bus-facing UART/GPIO/timer
   block rather than board-top glue.
4. Add UART RX and interrupt plumbing behind the same peripheral boundary.
5. Move Sv39 PTW/TLB into RTL once memory reads use the common interface.
6. Choose the xv6 disk path: SD-card SPI, UART loader, debug bridge, or host
   bridge.
7. Replace BRAM-only memory with a wider memory subsystem and run xv6 on it.

## Toolchain Note

Genesys 2 uses a Kintex-7 part. Depending on Vivado version/licensing, this may
require a licensed Vivado installation rather than the free WebPACK flow. Source
Vivado before running `make synth`, for example:

```bash
source /tools/Xilinx/Vivado/<version>/settings64.sh
```
