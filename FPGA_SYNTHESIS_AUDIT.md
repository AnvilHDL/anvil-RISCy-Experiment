# FPGA Synthesis Audit

This audit separates synthesizable project pieces from simulation services that
must be replaced before xv6 can run on Genesys 2 hardware.

## Current Synthesis Scope

The current FPGA target is a bounded synthesis smoke target:

```bash
scripts/export_fpga_rtl.sh
scripts/lint_fpga_rtl.sh
cd fpga && make synth
```

It exports `pipeline_core`, wraps it in `risky_genesys2_top`, and gives Vivado a
Genesys 2 part, top module, clock/reset pins, LEDs, UART idle, and fan output.

This proves that the generated processor RTL can enter the Vivado flow. It does
not yet prove xv6 can run on the board.

## File-By-File Boundary

| Path | FPGA status | Notes |
|------|-------------|-------|
| `src/core/top/pipeline_core.anvil` | synthesizable core RTL export | Owns pipeline, traps, CSRs, hazards, ALU/MUL/DIV, AMO, timer-pending state. Still consumes simulator-fed instruction/data memory and Sv39 translation registers. |
| `src/core/decode/*.anvil` | synthesizable helper RTL | Decode includes RV64 and Capstone opcode classification. |
| `src/core/execute/*.anvil` | synthesizable helper RTL | Integer ALU/branch logic is active. `cap_alu.anvil` is available but the main pipeline does not yet use it for architectural Capstone writeback. |
| `src/core/memory/*.anvil` | synthesizable helper RTL | Load/store alignment and AMO data shaping are active; backing memory is still external to RTL. |
| `src/core/csr/*.anvil` | synthesizable helper RTL | Scalar CSR/trap helper logic. |
| `src/core/hazard/*.anvil` | synthesizable helper RTL | Pipeline stall/forwarding logic. |
| `src/core/fetch/*.anvil` | synthesizable helper RTL | Thin fetch helper around externally supplied instruction data. |
| `src/core/writeback/*.anvil` | synthesizable helper RTL | Integer writeback muxing. |
| `src/types/*.anvilh` | synthesizable type definitions | Includes Capstone types, but type presence does not mean full Capstone hardware ownership. |
| `fpga/src/risky_genesys2_top.sv` | synthesis smoke wrapper | Deliberately minimal: clock/reset, core instance, heartbeat LEDs, UART TX idle, fan on. Not a full SoC. |
| `fpga/constraints/genesys2.xdc` | synthesis constraints | Board pin/clock constraints for the smoke wrapper. |
| `fpga/scripts/*.sh`, `fpga/scripts/*.tcl` | synthesis tooling | Vivado project/synthesis entry. Requires installed/sourced Vivado. |
| `scripts/export_fpga_rtl.sh` | FPGA export tooling | Runs only bounded Anvil generation; avoids full Verilator simulator build. |
| `scripts/lint_fpga_rtl.sh` | FPGA lint tooling | Verilator lint for wrapper plus generated core RTL. |
| `sim/*` | simulation only | ELF loading, host RAM, MMIO models, Sv39 PTW/TLB, virtio disk, and Capstone shadow state. Not synthesizable. |
| `tests/*` | verification only | ISA/program tests for simulation regressions. Not part of FPGA synthesis. |

## Required Replacements Before xv6-on-FPGA

| Simulation-owned feature | Current location | Hardware replacement needed |
|--------------------------|------------------|-----------------------------|
| Instruction/data RAM | `sim/sim_main.cpp` `host_mem[]` | BRAM boot memory plus DDR-backed memory subsystem or bus adapter. |
| ELF/kernel loading | `sim/sim_main.cpp` ELF loader | Boot ROM, debug loader, JTAG/UART loader, or flash/DDR initialization path. |
| Sv39 PTW/TLB | `sim/sim_main.cpp` `Sv39Tlb` and PTW state | RTL TLB plus multi-cycle page-table walker on the real memory interface. |
| CLINT MMIO attachment | `sim/sim_main.cpp` MMIO dispatch plus RTL timer counters | Real bus-visible CLINT/timer registers. |
| UART model | `sim/sim_main.cpp` UART/PLIC behavior | RTL UART and interrupt plumbing. |
| PLIC/external interrupts | `sim/sim_main.cpp` external pending injection | RTL interrupt controller or compatible interrupt path. |
| Virtio disk image | `sim/sim_main.cpp` virtio-blk model | SD card, SPI flash, RAM disk loader, or other board storage path. |
| Capstone architectural state | `sim/sim_main.cpp` `cap_rf[]` and `cap_tags[]` | RTL capability register file, tag memory, load/store, revocation, and trap enforcement. |
| Capability PC redirect | `sim/sim_main.cpp` Verilator internal pokes | RTL control-flow redirection in the pipeline. |

## Non-Production FPGA Wrapper Behavior

The current Genesys 2 top intentionally has only bring-up outputs:

- `tx` is held high so UART is electrically idle.
- `fan_pwm` is held high so the board fan remains enabled.
- LEDs show reset, heartbeat, and RX pin state.
- No real memory, UART, interrupt, storage, or boot-loader hardware is attached.

These are acceptable for synthesis smoke only. The wrapper must be replaced or
extended before board software execution is claimed.

## Capstone Status

Capstone is decoded and regression-tested in simulation, but it is not hardened
for FPGA synthesis yet. The main pipeline currently keeps `cap_result` as a
zero capability to avoid reintroducing the Anvil elaboration blowup that was
observed with wide capability struct muxing. The simulator owns the current
architectural capability behavior.

Capstone hardening should resume after the board can run xv6 with ordinary RV64
state, then move capability state into RTL in small scalarized slices.
