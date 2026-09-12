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

## 2026-09-12: reproducibility audit against Anvil upstream master

The repository was checked out on a clean machine and every README claim was
run. Results below; the two defects are open.

### Toolchains

Neither toolchain the build needs was present, and neither was obtainable from
the instructions as written:

- `anvil` was not in `PATH` and no build instructions were given.
- No RISC-V bare-metal compiler was installed, so all 21 ISA tests reported
  `COMPILE FAILED`.
- `scripts/check_fpga_boundary.sh` called `rg` unconditionally, so
  `verify_all.sh` failed for anyone without ripgrep.

`scripts/toolchain/install_anvil.sh` and
`scripts/toolchain/install_riscv_toolchain.sh` now install both under
`.toolchain/` without root, and the boundary check falls back to `grep`.

### Defect 1: Anvil literal evaluation (fixed here, upstream unfixed)

The core does not execute correctly on unmodified Anvil upstream `master`
(66e1294). `ParserHelper.{bit,dec,hex}_literal_of_string` builds digit lists
least-significant-digit first, but `Lang.literal_eval` folds them left, so a
sized literal evaluates to its digits reversed: `5'd17` becomes 71, `5'd23`
becomes 32.

`literal_eval` drives constant array indices and generated enum constants, so
the effects are broad:

- The register file `set regs_q[cur_mem_wb.rd] := wb_data` and reads such as
  `*regs_q[17]` resolve to the wrong element. No program retired a correct
  register value; `li a7, 93` left `0xFFFFFFFFFFFFFFFF` in x17.
- Generated enum constants were wrong: `ALU_DIVU = 5'd23` emitted as `5'd32`,
  and `5'd27` as `5'd72`, which does not even fit the declared width.
  Diffing generated SystemVerilog before and after the fix shows 580 changed
  lines.
- Indices whose reversal stays in range (12 -> 21, 13 -> 31) are silently
  wrong rather than caught by the bounds check.

Fixed by folding from the right, in
`third_party/anvil-patches/0001-fix-literal_eval-digit-order.patch`. Anvil's
own typechecking and simulation suites pass with it applied. The patch has not
been sent upstream.

With the patch the register file, forwarding, arithmetic, CSR read/write and
the `a7 == 93` simulator-exit path all behave correctly.

### Defect 2: pipeline wedges permanently (open)

The pipeline can stop advancing for good, and never reaches the program's
`ecall`, so `sim_exit_valid_q` never latches and the run burns its whole cycle
budget. There are two independent triggers; neither involves the other.

**Trigger A — any CSR write.** Reproducer: `tests/regress/csrw_wedge.S`.

```
li t0, 42
csrw mscratch, t0     # wedges
```

CSR *reads* are fine: `csrr t1, mscratch` alone retires in ~12 cycles. Every
CSR write tried wedges (`mtvec`, `mscratch`, `mepc`, `mcause`, `satp`), for
every immediate value tried, at any distance from the instruction producing
its operand. This is what stops the ISA tests: their `RVTEST_CODE_BEGIN`
prologue does `csrw mtvec, t0`, and most of them never divide at all.

**Trigger B — DIV/REM whose operands are not forwarded.** Reproducer:
`tests/regress/div_stall_hang.S`.

With `div t2, t0, t1` directly after the two `li`s that set its operands the
program retires in ~79 cycles. Insert one `nop` and it wedges. Traced:

1. The divider runs its 64 iterations and completes normally: `div_busy_q`
   returns to 0 with `div_count_q == 64`.
2. During the stall the PC correctly freezes and IF/ID, ID/EX and MEM/WB hold
   their packets, as the `pipeline_stall` arms of `next_pc` / `next_if_id` /
   `next_mem_wb` intend.
3. On release the PC advances `0x80000018 -> 0x8000001c -> 0x80000020` in
   consecutive cycles, but ID/EX only receives `li a7, 93` then `li a0, 0`.
   The `ecall` never reaches ID/EX with a valid packet.
4. The machine then wedges with ID/EX holding `li a0, 0` and MEM/WB holding
   the DIV. Neither retires, so `a7` and `a0` stay 0.

MUL is unaffected.

**Common shape.** In the wedged state none of the documented stall sources is
asserted: `div_busy_q == 0`, `sv39_stall_q == 0`, and the MEM/WB packet has no
exception, so `pipeline_stall` is false, yet no pipeline register updates.
The register-file write event is gated on `wb_fire`
(`valid && !has_exc && reg_write && rd != 0 && !int_fire && !pipeline_stall`),
and the generated SystemVerilog for that condition matches the Anvil source.
This points at a core stall/handshake defect rather than a codegen fault.
Both triggers reproduce with the patched compiler, so both are independent of
defect 1.

### Current test results

Run with both toolchains from `scripts/toolchain/`:

| Check | Result |
| --- | --- |
| Shell syntax | pass |
| FPGA boundary documentation | pass (after the `rg` fix) |
| Simulator build (Anvil + Verilator) | pass |
| ISA regression | 0/21 — all block on defect 2 (trigger A) |
| C++ program regression | 0/8 — defect 2 |
| Generated SystemVerilog lint | pass |
| FPGA RTL export/lint | pass |
| FPGA BRAM export/lint | pass |
| xv6 smoke | not run; no kernel or fs.img available on this machine |

The xv6 boot-to-shell claim could not be checked. No `xv6-riscv` tree,
`kernel` ELF or `fs.img` is present, and `scripts/run_xv6_smoke.sh` requires
both. Since the ISA suite does not pass, that claim should be treated as
unverified until defect 2 is fixed and the images are supplied.

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
