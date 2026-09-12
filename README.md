# RISCy-Experiment

An experimental five-stage RV64 processor written in
[Anvil](https://github.com/kisp-nus/anvil). Anvil generates SystemVerilog,
which runs under Verilator or feeds the Genesys 2 FPGA flows in this
repository.

Under Verilator the core runs the RISC-V ISA tests, freestanding C++ programs,
and xv6-riscv to a shell prompt.

## Requirements

- The Anvil compiler, as `anvil` in `PATH` or via `ANVIL_BIN`. Upstream
  `master` at commit `8432f2b` or later; earlier revisions mis-evaluate sized
  literals and the core will not execute correctly.
- Verilator 4.2 or newer
- GNU Make, `git`, `curl`
- Vivado with Kintex-7 support, for FPGA synthesis only

The RISC-V cross-toolchain is not required up front: the scripts install a
prebuilt one into `.toolchain/` without root.

## Quick start

Clone with submodules, then boot xv6:

```bash
git clone --recurse-submodules <repo-url>
cd RISCy-Experiment
scripts/run_xv6.sh
```

`run_xv6.sh` performs every step needed and skips those already done: check
out the xv6 submodule, install the RISC-V toolchain, build xv6 for this core's
ISA, build the simulator, and boot. It prints a progress bar while booting and
stops once the shell prompt appears.

Expected output:

```
xv6 kernel is booting

init: starting sh
$
```

Pass `-i` to stay attached to the shell instead of stopping at the prompt.

### Boot time

**Expect roughly 7 minutes to reach the shell prompt.** Measured at 396 s on a
desktop x86-64 machine; the simulator runs at about 200 000 cycles per second
and the boot needs on the order of 10^8 cycles, so the figure scales with
single-core performance. The first run takes longer still, because it also
downloads the toolchain (about 520 MB) and builds xv6 and the simulator.

`XV6_CYCLE_LIMIT` (default 2 000 000 000) bounds the run in simulated cycles.
`XV6_HOST_TIMEOUT` (default `0`, meaning no limit) bounds it in wall clock.

## Build and test

```bash
# Build the Verilator simulator.
scripts/build_program_sim.sh

# Run the ISA and C++ program regressions, lints and FPGA export checks.
scripts/verify_all.sh

# Run one ISA test.
build/pipeline_core_program/obj_dir/Vpipeline_core tests/isa/csr.elf 100000
```

To include the xv6 boot in the full run:

```bash
RUN_XV6=1 \
XV6_KERNEL="$PWD/.toolchain/xv6-build/kernel/kernel" \
XV6_FS_IMG="$PWD/.toolchain/xv6-build/fs.img" \
XV6_CYCLE_LIMIT=2000000000 \
XV6_HOST_TIMEOUT=0 \
VERIFY_XV6_TIMEOUT=0 \
scripts/verify_all.sh
```

Anvil compilation is bounded by a 12 GiB virtual-memory limit and a 20-minute
timeout, both configurable:

```bash
ANVIL_BIN=/path/to/anvil ANVIL_VMEM_MB=16384 ANVIL_TIMEOUT=30m \
  scripts/build_program_sim.sh
```

`ANVIL_VMEM_MB=0` disables the memory limit.

### Simulator output

The simulator prints the guest console on stdout and a few startup lines on
stderr. Pass `--verbose` for the full per-cycle trace (page-table walks, UART
and PLIC activity, traps, privilege changes), or `--trace` for pipeline
tracing.

## xv6

xv6-riscv is vendored as a submodule at `third_party/xv6-riscv`. Stock xv6
targets `rv64gc` with the `lp64d` ABI, which this core does not implement, so
`scripts/toolchain/build_xv6.sh` rebuilds it for `rv64ima_zicsr_zifencei` with
`-mabi=lp64`, `NCPU=1` and `PHYSTOP=0x80800000`. It builds out of tree into
`.toolchain/xv6-build`, leaving the submodule's working tree untouched.

## Architecture

Five-stage in-order pipeline:

| Stage | Responsibility |
| --- | --- |
| IF | Instruction fetch and PC selection |
| ID | Decode, register reads, forwarding, hazard detection |
| EX | Integer, branch, CSR and capability operations |
| MEM | Loads, stores, atomics, alignment, memory exceptions |
| WB | Register writeback, retirement, traps, redirects |

Implemented: RV64I, RV64M, RV64A atomics, M/S/U privilege transitions, traps
and interrupts, and Sv39. Capability instructions are present as an
experimental extension.

The Verilator harness supplies RAM, the Sv39 page-table walker and TLB, MMIO
devices, virtio block storage, and part of the capability state. These are not
all available in synthesizable RTL; see [docs/WORK_LOG.md](docs/WORK_LOG.md)
for the boundary between the two and the open work.

## FPGA

Genesys 2 targets for synthesis checks, BRAM bring-up and DDR integration:

```bash
scripts/lint_fpga_rtl.sh
scripts/lint_fpga_bram_rtl.sh

make -C fpga check
make -C fpga bram
make -C fpga bitstream-bram
```

The FPGA targets do not yet provide every service the simulator does. See
[fpga/README.md](fpga/README.md) for board setup and programming.

## Repository layout

| Path | Contents |
| --- | --- |
| `src/` | Anvil types, pipeline stages, CSR logic, execution units |
| `sim/` | Verilator harness, linker script, startup code |
| `tests/` | ISA assembly tests and freestanding C++ programs |
| `scripts/` | Build, test, export and lint entry points |
| `fpga/` | Genesys 2 wrappers, constraints, Vivado scripts, Makefile |
| `third_party/xv6-riscv` | xv6-riscv submodule |
| `docs/WORK_LOG.md` | Implementation boundary and open engineering work |

See also [scripts/README.md](scripts/README.md),
[sim/README.md](sim/README.md) and [tests/README.md](tests/README.md).
