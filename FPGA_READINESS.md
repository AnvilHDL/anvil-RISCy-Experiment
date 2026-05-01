# FPGA Readiness

This project is currently a robust Verilator bring-up target, not yet a complete
FPGA-ready processor.

The final goal is:

1. boot xv6-riscv on the implementation,
2. replace simulation-only services with synthesizable RTL,
3. synthesize on FPGA with real memory and devices,
4. keep ISA and xv6 regressions passing throughout.

## Current Bring-Up Boundary

The Anvil RTL owns the 5-stage in-order RV64 pipeline, decode, ALU/MUL,
branching, CSR/trap flow, register file, load/store alignment, AMO behavior,
and pipeline hazards.

The Verilator harness currently owns several services that are required for a
complete hardware processor:

| Area | Current owner | FPGA-ready replacement needed |
|------|---------------|-------------------------------|
| Instruction/data RAM | C++ `host_mem[]` | BRAM/AXI memory subsystem |
| Sv39 page-table walk | C++ TLB/PTW | RTL TLB plus multi-cycle PTW FSM |
| CLINT timer | RTL `mtime`/`mtimecmp`/`stimecmp` pending path with C++ MMIO shim | Real bus attachment for MMIO |
| PLIC/UART/virtio | C++ MMIO models | RTL peripherals or bus adapters |
| Capability register file | C++ shadow state for several ops | RTL capability RF and cap ALU integration |
| xv6 disk | C++ virtio-blk image model | FPGA storage path or host bridge |

Do not treat a Verilator pass as FPGA readiness. It proves architectural
behavior for the current simulation contract.

## Robust Verification Entry Point

Use:

```bash
scripts/verify_all.sh
```

This runs shell syntax checks, a guarded simulator build, the ISA regression,
an FPGA-boundary check, the C++ program regression, and generated-SystemVerilog
lint. The scripts use host timeouts and Anvil memory limits so failed
builds/tests terminate instead of hanging indefinitely.

The FPGA-boundary check intentionally fails if stale harness patches for RTL
features reappear, or if known simulation-backed services stop being documented.

When xv6 artifacts are available, include the boot smoke:

```bash
RUN_XV6=1 XV6_KERNEL=/path/to/xv6-riscv/kernel/kernel \
    XV6_FS_IMG=/path/to/xv6-riscv/fs.img scripts/verify_all.sh
```

The smoke watches the boot log and terminates the simulator once the xv6 shell
prompt appears, so a successful boot does not run until the full cycle budget.

## FPGA Milestones

1. Keep `scripts/verify_all.sh` passing on every change.
2. Add a synthesizable memory interface and replace `host_mem[]` assumptions.
3. Add an RTL Sv39 TLB/PTW with bounded multi-cycle stalls.
4. Add UART, PLIC, and external interrupt paths in RTL or behind a real bus.
5. Decide the FPGA storage path for xv6 filesystem access.
6. Run xv6 in Verilator without simulation-only architectural patches.
7. Add synthesis constraints, BRAM mapping, clocks/resets, and timing closure.

Any feature that depends on the C++ harness should be marked simulation-backed
until the corresponding RTL replacement exists and is covered by tests.
