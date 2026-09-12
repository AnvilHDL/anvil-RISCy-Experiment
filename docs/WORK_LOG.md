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
run. Two defects blocked every simulation regression; both are fixed here, and
`scripts/verify_all.sh` now passes end to end including the xv6 boot.

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

### Defect 2: pipeline wedged permanently (fixed)

The pipeline could stop advancing for good and never reach the program's
`ecall`, so `sim_exit_valid_q` never latched and the run burned its whole
cycle budget. Two triggers, one root cause:

- **any CSR write whose operand comes from a register**
  (`tests/regress/csrw_wedge.S`). CSR *reads* were fine, and so were
  `csrwi`/`csrw x0` — the wedge needed the register dependency.
- **DIV/REM whose operands are not forwarded from the two preceding
  instructions** (`tests/regress/div_stall_hang.S`). The divider itself
  completed correctly; inserting one `nop` before the DIV was enough to wedge.

**Root cause.** In the wedged state no stall source was asserted
(`div_busy_q == 0`, `sv39_stall_q == 0`, `mip == mie == 0` so `int_fire` was
false, no exception in MEM/WB), so `pipeline_stall` and `wb_fire` both
evaluated the way a retiring instruction needs. Nothing updated anyway,
because the Anvil thread had stopped scheduling:

```
[T 14] ... ev125=1 ev128=0 ev132=0    join130=0
[T 15] ... ev125=0 ev128=0 ev132=0    join130=1   <- thread stops here
```

The loop closes through `EVENTS0[0] <- EVENTS0[133] <- EVENTS0[132] |
EVENTS0[130]`, where 132 is the boot arm, so steady state depends entirely on
`EVENTS0[130]`. That is a join of `EVENTS0[129]` and `EVENTS0[125]`, tracked
by `_thread_0_event_reg_130_q`. At T15 the register latched to 1 because only
the `EVENTS0[129]` side arrived; `EVENTS0[125]` never did, the join never
completed, and every pipeline register held indefinitely.

The two arms came from the one statement-level `if` in the cycle body:

```
if wb_fire == 1'b1 { set regs_q[cur_mem_wb.rd] := wb_data } else { () };
```

which the compiler lowers to `EVENTS0[127]` / `EVENTS0[126]`, both gated on
`wb_fire`.

**Fix.** Write unconditionally and steer suppressed writes at x0, which is
architecturally hardwired to zero. Every indexed reader of `regs_q` already
special-cases index 0, and the two direct reads are of x10 and x17, so
retargeting a suppressed write at x0 is a no-op:

```
let wb_idx = if wb_fire == 1'b1 { cur_mem_wb.rd } else { <(5'd0)::reg_idx_t> } >>
let wb_commit = if wb_fire == 1'b1 { wb_data } else { <(64'd0)::xlen_t> } >>
set regs_q[wb_idx] := wb_commit;
```

This removes the branch, so the cycle body has a single control path and the
join cannot half-complete.

### Current test results

Run with the toolchains from `scripts/toolchain/`, `scripts/verify_all.sh`
passes end to end:

| Check | Result |
| --- | --- |
| Shell syntax | pass |
| FPGA boundary documentation | pass |
| Simulator build (Anvil + Verilator) | pass |
| ISA regression | 21/21 pass |
| C++ program regression | 8/8 pass |
| Generated SystemVerilog lint | pass |
| FPGA RTL export/lint | pass |
| FPGA BRAM export/lint | pass |
| xv6 smoke | pass — boots to the shell prompt |

xv6 console output:

```
xv6 kernel is booting

init: starting sh
$
```

Boot reaches `$` at roughly 81 M cycles, so the smoke test needs a raised
limit; `XV6_CYCLE_LIMIT` defaults to 30 M, which stops during `kinit`'s page
clearing. Use:

```bash
XV6_CYCLE_LIMIT=400000000 XV6_HOST_TIMEOUT=900s scripts/run_xv6_smoke.sh
```

Stock xv6 does not run as shipped: it targets `rv64gc` with the `lp64d` ABI,
and this core implements RV64IMA with Zicsr/Zifencei, no compressed
instructions and no floating point. `scripts/toolchain/build_xv6.sh` clones
xv6 and applies `third_party/xv6-patches/`, which sets the ISA and ABI,
`NCPU = 1`, and `PHYSTOP = 0x80800000`.

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

With xv6 (build the images first with `scripts/toolchain/build_xv6.sh`):

```bash
RUN_XV6=1 \
XV6_KERNEL="$PWD/.toolchain/xv6-riscv/kernel/kernel" \
XV6_FS_IMG="$PWD/.toolchain/xv6-riscv/fs.img" \
XV6_CYCLE_LIMIT=400000000 \
VERIFY_XV6_TIMEOUT=900s \
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
