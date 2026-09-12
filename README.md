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

Anvil upstream `master` needs commit `8432f2b` ("fix literal eval") or later;
before it, sized literals evaluate with their digits reversed and the core
does not execute correctly.

Stock xv6 targets `rv64gc`, which this RV64IMA core does not implement.
`scripts/toolchain/build_xv6.sh` rebuilds it for the right ISA.

See [the work log](docs/WORK_LOG.md) for both, and for the pipeline defect
that was fixed to get here.

## Requirements

- The Anvil compiler, available as `anvil` in `PATH` or selected with
  `ANVIL_BIN` (upstream `master` at `8432f2b` or later)
- Verilator 4.2 or newer
- GNU Make
- Vivado with Kintex-7 support for FPGA synthesis and programming

A RISC-V bare-metal toolchain is installed under `.toolchain/` without root:

```bash
scripts/toolchain/install_riscv_toolchain.sh
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

One command, from a clean checkout to a booted shell:

```bash
scripts/run_xv6.sh
```

It checks out the xv6 submodule, installs the RISC-V toolchain, builds xv6 for
this core's ISA, builds the simulator, and boots — skipping any step already
done. Add `-i` to stay attached to the shell instead of stopping at the
prompt.

Stock xv6 targets `rv64gc` with the `lp64d` ABI, which this core cannot
execute; `scripts/toolchain/build_xv6.sh` rebuilds it for
`rv64ima_zicsr_zifencei` with `-mabi=lp64` and sets `NCPU=1` and
`PHYSTOP=0x80800000`. It builds out of tree into `.toolchain/xv6-build`, so
the submodule's working tree is left untouched.

Boot reaches the shell prompt at roughly 81 M cycles, which takes a few
minutes of wall clock. The console output is:

```
xv6 kernel is booting

init: starting sh
$
```

To include xv6 in the full verification run:

```bash
RUN_XV6=1 \
XV6_KERNEL="$PWD/.toolchain/xv6-build/kernel/kernel" \
XV6_FS_IMG="$PWD/.toolchain/xv6-build/fs.img" \
XV6_CYCLE_LIMIT=400000000 \
XV6_HOST_TIMEOUT=900s \
VERIFY_XV6_TIMEOUT=950s \
scripts/verify_all.sh
```

`XV6_CYCLE_LIMIT` defaults to 30 M, which stops partway through `kinit`.
`XV6_HOST_TIMEOUT` bounds the simulator and `VERIFY_XV6_TIMEOUT` the wrapper
around it; both must exceed the boot time.

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
