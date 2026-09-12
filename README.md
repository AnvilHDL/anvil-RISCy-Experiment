# RISCy-Experiment

RISCy-Experiment is an experimental five-stage RV64 processor written in
[Anvil](https://github.com/kisp-nus/anvil). Anvil generates SystemVerilog,
which can be run with Verilator or integrated into the Genesys 2 FPGA flows in
this repository.

The Verilator target is the development target for the RISC-V ISA tests,
freestanding C++ programs, and xv6-riscv. The FPGA targets are under
development and do not yet provide every service used by the simulator.

## Status

`scripts/verify_all.sh` passes end to end: 21/21 ISA tests, 8/8 freestanding
C++ programs, the lint and FPGA export checks, and the xv6 smoke test, which
boots to a shell prompt.

Two things are needed to reproduce that, both automated by
`scripts/toolchain/`:

- Anvil upstream `master` mis-evaluates sized literals, which corrupts
  constant array indices and generated enum constants. The fix is in
  [third_party/anvil-patches/](third_party/anvil-patches/).
- Stock xv6 targets `rv64gc`, which this RV64IMA core does not implement. The
  ISA, ABI, `NCPU` and `PHYSTOP` changes are in
  [third_party/xv6-patches/](third_party/xv6-patches/).

See [the work log](docs/WORK_LOG.md) for both, and for the pipeline defect
that was fixed to get here.

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

### xv6

Build a kernel and filesystem image that this core can run:

```bash
scripts/toolchain/build_xv6.sh
```

That clones xv6-riscv into `.toolchain/` and applies
[third_party/xv6-patches/](third_party/xv6-patches/), which builds for
`rv64ima_zicsr_zifencei` with `-mabi=lp64` (this core has no compressed
instructions and no floating point) and sets `NCPU=1` and
`PHYSTOP=0x80800000`.

Then boot it:

```bash
XV6_KERNEL="$PWD/.toolchain/xv6-riscv/kernel/kernel" \
XV6_FS_IMG="$PWD/.toolchain/xv6-riscv/fs.img" \
XV6_CYCLE_LIMIT=400000000 \
XV6_HOST_TIMEOUT=900s \
scripts/run_xv6_smoke.sh
```

Boot reaches the shell prompt at roughly 81 M cycles, so the default
`XV6_CYCLE_LIMIT` of 30 M is not enough — it stops partway through `kinit`.
The console output is:

```
xv6 kernel is booting

init: starting sh
$
```

The same variables work with `RUN_XV6=1 scripts/verify_all.sh` to include the
smoke test in the full run.

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

All of the above are exercised by the regressions, which pass, including xv6
booting to a shell.

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
