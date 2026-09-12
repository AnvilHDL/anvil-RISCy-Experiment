# RISCy-Experiment

RISCy-Experiment is an experimental five-stage RV64 processor written in
[Anvil](https://github.com/kisp-nus/anvil). Anvil generates SystemVerilog,
which can be run with Verilator or integrated into the Genesys 2 FPGA flows in
this repository.

The Verilator target runs the RISC-V ISA tests, freestanding C++ programs, and
xv6-riscv. The FPGA targets are under development and do not yet provide every
service used by the simulator.

## Requirements

- Anvil from the upstream `master` branch, available as `anvil` in `PATH`
  or selected with `ANVIL_BIN`
- Verilator 4.2 or newer
- GNU Make
- A RISC-V bare-metal C++ compiler, or Clang with the RISC-V target and LLD
- Vivado with Kintex-7 support for FPGA synthesis and programming

## Build and test

```bash
# Build the Verilator simulator.
scripts/build_program_sim.sh

# Run the ISA and freestanding C++ regressions.
scripts/verify_all.sh

# Run a single ISA test.
build/pipeline_core_program/obj_dir/Vpipeline_core tests/isa/csr.elf 100000
```

Anvil compilation has a 12 GiB virtual-memory limit and a 20-minute timeout by
default. Both are configurable:

```bash
ANVIL_BIN=/path/to/anvil \
ANVIL_VMEM_MB=16384 \
ANVIL_TIMEOUT=30m \
scripts/build_program_sim.sh
```

Set `ANVIL_VMEM_MB=0` to disable the memory limit.

To include the xv6 smoke test:

```bash
RUN_XV6=1 \
XV6_KERNEL=/path/to/xv6-riscv/kernel/kernel \
XV6_FS_IMG=/path/to/xv6-riscv/fs.img \
scripts/verify_all.sh
```

The xv6 image is expected to use `NCPU=1` and `PHYSTOP=0x80800000`.

## Architecture

The core implements a five-stage in-order pipeline:

| Stage | Main responsibility |
| --- | --- |
| IF | Instruction fetch and PC selection |
| ID | Decode, register reads, forwarding, and hazard detection |
| EX | Integer, branch, CSR, and capability operations |
| MEM | Loads, stores, atomics, alignment, and memory exceptions |
| WB | Register writeback, retirement, traps, and redirects |

Implemented and regression-tested simulation features include RV64I, RV64M,
RV64A atomics, M/S/U privilege transitions, traps and interrupts, Sv39, and
xv6 boot to a shell. Capability instructions are present as an experimental
extension.

The simulation harness currently supplies RAM, the Sv39 page-table walker and
TLB, MMIO devices, virtio block storage, and part of the capability state.
These are not all implemented in synthesizable RTL. See
[the work log](docs/WORK_LOG.md) for the exact boundary and pending work.

## FPGA

The FPGA directory contains Genesys 2 targets for synthesis checks, BRAM
bring-up, and DDR integration:

```bash
scripts/lint_fpga_rtl.sh
scripts/lint_fpga_bram_rtl.sh
scripts/lint_fpga_ddr_rtl.sh

make -C fpga check
make -C fpga bram
make -C fpga bitstream-bram
```

See [fpga/README.md](fpga/README.md) for board setup and programming commands.

## Repository layout

| Path | Contents |
| --- | --- |
| `src/` | Anvil types, pipeline stages, CSR logic, and execution units |
| `sim/` | Verilator harness, linker script, and startup code |
| `tests/` | ISA assembly tests and freestanding C++ programs |
| `scripts/` | Build, test, export, and lint entry points |
| `fpga/` | Genesys 2 wrappers, constraints, Vivado scripts, and Makefile |
| `docs/WORK_LOG.md` | Current implementation boundary and open engineering work |

Additional details are in [scripts/README.md](scripts/README.md),
[sim/README.md](sim/README.md), and [tests/README.md](tests/README.md).
