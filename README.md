# RISCy-Experiment

RISCy-Experiment is an experimental five-stage RV64 processor written in
[Anvil](https://github.com/kisp-nus/anvil). Anvil generates SystemVerilog,
which can be run with Verilator or integrated into the Genesys 2 FPGA flows in
this repository.

The Verilator target is the development target for the RISC-V ISA tests,
freestanding C++ programs, and xv6-riscv. The FPGA targets are under
development and do not yet provide every service used by the simulator.

## Status

The core builds and runs under Verilator, but the simulation regressions do
**not** currently pass. `scripts/verify_all.sh` fails at the ISA stage. See
[the work log](docs/WORK_LOG.md) for the open defect (the pipeline wedges
permanently on any CSR write, and on some DIV/REM sequences) and for what has
been verified to work.

Anvil upstream `master` also needs a compiler fix before the core executes
correctly; `scripts/toolchain/install_anvil.sh` applies it. See
[third_party/anvil-patches/](third_party/anvil-patches/).

## Requirements

- OCaml with opam, and the Anvil build dependencies (`menhir`, `yojson`,
  `dune`), to build the Anvil compiler
- Verilator 4.2 or newer
- GNU Make
- Vivado with Kintex-7 support for FPGA synthesis and programming

`scripts/toolchain/` provides the two toolchains that are not usually present
on a clean machine, installing both under `.toolchain/` without root:

```bash
# Build Anvil from upstream master with the required patch applied.
scripts/toolchain/install_anvil.sh

# Install a prebuilt riscv64 bare-metal GCC.
scripts/toolchain/install_riscv_toolchain.sh
```

Then point the build at them:

```bash
export ANVIL_BIN="$PWD/.toolchain/anvil/_build/default/bin/main.exe"
export PATH="$PWD/.toolchain/riscv/bin:$PATH"
```

## Build and test

```bash
# Build the Verilator simulator.
scripts/build_program_sim.sh

# Run the ISA and freestanding C++ regressions.
# Currently fails at the ISA stage; see docs/WORK_LOG.md.
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

The core implements RV64I, RV64M, RV64A atomics, M/S/U privilege transitions,
traps and interrupts, and Sv39. Capability instructions are present as an
experimental extension.

These are implemented, not currently regression-passing: the ISA and C++
program suites fail because of the pipeline-wedge defect recorded in the work
log, and the xv6 boot-to-shell result has not been reproduced since. Treat the
feature list as the intended scope rather than as a passing test matrix.

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
