# Work log

This file records the current implementation boundary and pending engineering
work. Stable setup and usage instructions belong in the repository README files.

## 2026-09-12: repository and Pact compatibility cleanup

- Removed machine-specific Anvil and Vivado paths from scripts.
- Replaced implicit mixed-width concatenation with Pact `master`'s explicit
  `#flat{...}` construct.
- Replaced compiler-branch built-ins `copy`, `shl_dyn`, and `shr_dyn` with
  standard register reads and `shl`/`shr` operators.
- Replaced arithmetic type widths with literal widths accepted by Pact
  `master`.
- Separated project usage documentation from this status log.

## Current implementation boundary

The Anvil core contains the five-stage RV64 pipeline, decode, integer and
multiply/divide execution, branches, CSRs, traps, register state, load/store
alignment, atomics, interrupts, and pipeline hazard handling.

The Verilator harness still supplies services that require RTL replacements for
a complete FPGA system:

| Service | Simulation implementation | FPGA work |
| --- | --- | --- |
| Memory | C++ `host_mem[]` | BRAM or DDR-backed memory subsystem |
| Address translation | C++ Sv39 TLB and page-table walker | RTL TLB/PTW |
| Timer MMIO | C++ MMIO access to RTL `mtime`/`mtimecmp`/`stimecmp` state | Bus attachment |
| UART, PLIC, and virtio | C++ device models | RTL peripherals or bus adapters |
| Capability state | C++ capability register-file support | RTL capability register file and datapath |
| xv6 storage | C++ virtio block image | FPGA storage or host bridge |

The Verilator regressions exercise the simulation contract. FPGA readiness also
requires the corresponding services to be synthesizable and integrated with the
core.

## FPGA status

The selected board is the Digilent Genesys 2
(`XC7K325T-2FFG900C`). The repository currently provides:

- a generated-core synthesis target;
- a BRAM bring-up target with GPIO, UART TX/RX, timer readback, and minimal PLIC
  wiring;
- a DDR/MIG integration target and calibration target.

The BRAM bring-up payload writes `BOOT\r\nB\r\nL=5A\r\n` over UART and
writes `0x5a` to the GPIO window. It is a board bring-up program, not an xv6
system.

The generated core exposes interrupt and Sv39-related signals, but the FPGA
system does not yet include a complete RTL Sv39 path or xv6 storage path.
Capability execution is also incomplete in RTL; `cap_result` remains zeroed
in the main pipeline until that state is integrated.

## Verification

The standard local check is:

```bash
scripts/verify_all.sh
```

It runs shell syntax checks, a bounded simulator build, ISA tests, C++ program
tests, the FPGA boundary check, and generated-SystemVerilog lint.

When xv6 artifacts are available:

```bash
RUN_XV6=1 \
XV6_KERNEL=/path/to/xv6-riscv/kernel/kernel \
XV6_FS_IMG=/path/to/xv6-riscv/fs.img \
scripts/verify_all.sh
```

FPGA-focused checks:

```bash
scripts/export_fpga_rtl.sh
scripts/lint_fpga_rtl.sh
scripts/export_fpga_bram_rtl.sh
scripts/lint_fpga_bram_rtl.sh
make -C fpga check
make -C fpga bram
make -C fpga synth
```

## Open work

1. Complete and validate the DDR-backed memory path.
2. Add a stall-capable shared memory interface.
3. Attach a synthesizable Sv39 TLB/PTW to that interface.
4. Keep UART, PLIC, GPIO, and timer devices behind the common MMIO boundary.
5. Select and implement an xv6 storage path.
6. Integrate the capability register file and capability ALU in RTL.
7. Run xv6 on the board and close timing on the Genesys 2 target.
