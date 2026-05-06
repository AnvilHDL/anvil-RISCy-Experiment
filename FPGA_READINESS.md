# FPGA Readiness

This project is currently a robust Verilator bring-up target, not yet a complete
FPGA-ready processor.

The final goal is:

1. boot xv6-riscv on the implementation,
2. replace simulation-only services with synthesizable RTL,
3. synthesize on FPGA with real memory and devices,
4. keep ISA and xv6 regressions passing throughout.

The selected FPGA target is Digilent Genesys 2, following a CVA6-like
repository shape with `fpga/constraints`, `fpga/scripts`, and `fpga/src`.

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

The tracked source tree should not contain demo instruction/data memories. The
current core exposes fetch/load data registers and store commit side channels;
`sim/sim_main.cpp` models memory only for Verilator. The FPGA path must attach
real BRAM/DDR and MMIO hardware rather than relying on simulator memory.

The BRAM bring-up target (`fpga/src/risky_genesys2_bram_top.sv`) is the first
board-facing software execution step. It uses a generated
`pipeline_core_bram_if` wrapper, a small synthesizable BRAM, and an LED MMIO
store path so a tiny bare-metal program can execute on Genesys 2 without adding
large memories to Anvil. This is still not the xv6 SoC; it is the bounded
hardware bridge used before UART, DDR, interrupts, storage, and RTL Sv39 are
added.

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

## Genesys 2 FPGA Entry Point

Use:

```bash
scripts/export_fpga_rtl.sh
scripts/lint_fpga_rtl.sh
scripts/export_fpga_bram_rtl.sh
scripts/lint_fpga_bram_rtl.sh
cd fpga && make check
cd fpga && make bram
cd fpga && make bitstream-bram
cd fpga && make synth
```

`scripts/export_fpga_rtl.sh` runs only bounded Anvil generation and does not run
Verilator, so FPGA RTL export avoids the larger simulator build path. The Vivado
synthesis target is a smoke wrapper for Genesys 2 (`XC7K325T-2FFG900C`) that
packages the current core behind board clock/reset/LED/UART pins.

This wrapper is intentionally not yet a complete xv6-capable FPGA SoC. It is the
stable integration point for replacing `host_mem[]`, Sv39 PTW, UART/PLIC/virtio,
and disk simulation services with synthesizable hardware.

Current non-production wrapper behavior:

- the board top owns MMCM clocking, reset release, BRAM staging, and heartbeat.
- the BRAM path uses a separate FPGA peripheral block for GPIO, NS16550-style
  UART TX/RX, minimal PLIC/SEIP wiring, and CLINT load readback instead of
  wrapper-generated text state machines.
- BRAM bring-up drives the NS16550-style UART THR/LSR addresses
  (`0x10000000`, `0x10000005`) and a simple GPIO MMIO window at `0x10000008`.
- the bundled BRAM bring-up payload writes `BOOT\r\nB\r\nL=5A\r\n` in software.
- LEDs show reset, heartbeat, and the low six bits of the GPIO byte.
- The BRAM target now exports external interrupt and Sv39-side signals from the
  generated core, but a full attached RTL PTW/TLB and DDR-backed memory path are
  still missing.
- No storage or boot-loader hardware is attached.

These are acceptable for synthesis smoke only. Do not claim board software
execution until the wrapper is extended into a real SoC.

Capstone is decoded and regression-tested in simulation, but it is not hardened
for FPGA synthesis yet. The main pipeline currently keeps `cap_result` zeroed
until capability state is migrated in bounded scalarized RTL slices.

## FPGA Milestones

1. Keep `scripts/verify_all.sh` passing on every change.
2. Run the BRAM-backed LED MMIO target on Genesys 2.
3. Replace the generated BRAM bridge with a first-class Anvil memory interface.
4. Attach an RTL Sv39 TLB/PTW with bounded multi-cycle stalls to the exported
   core-side translation boundary.
5. Keep the UART/PLIC/GPIO/timer peripheral block behind the same MMIO
   boundary and extend it only through that interface.
6. Replace BRAM-only execution with a DDR/MIG-backed memory subsystem.
7. Decide the xv6 storage path for filesystem access.
8. Run xv6 in Verilator without simulation-only architectural patches and keep timing
   closure intact on Genesys 2.

Any feature that depends on the C++ harness should be marked simulation-backed
until the corresponding RTL replacement exists and is covered by tests.
