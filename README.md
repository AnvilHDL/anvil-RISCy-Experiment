# RISCy-Experiment

A hand-built RV64 processor implemented in **Anvil HDL**, compiled via SystemVerilog to a Verilator simulation, capable of booting **xv6-riscv** to a shell prompt.

```
xv6 kernel is booting

init: starting sh
$
```

The design prioritises architectural correctness over microarchitectural optimisation — every instruction retires precisely, every trap is delivered to the right privilege level, and the virtual-memory page table walk is faithful to the RISC-V privileged specification.

---

## Pipeline Architecture

```mermaid
graph LR
    IF["IF\nInstruction Fetch\npc_q → imem_rdata_q"] -->|if_id_pkt_t| ID
    ID["ID\nDecode + Regfile Read\nctrl signals, immediates"] -->|id_ex_pkt_t| EX
    EX["EX\nALU / Branch / CSR\nalu_result, branch target"] -->|ex_mem_pkt_t| MEM
    MEM["MEM\nLoad / Store / AMO\nmem_rdata, mem_store"] -->|mem_wb_pkt_t| WB
    WB["WB\nWriteback + Trap\nrd ← result, CSR update"] -->|"PC redirect\n(trap / branch)"| IF

    FWD["Forwarding\nEX→ID, MEM→ID"] -.->|bypass| ID
    HAZ["Hazard\nload-use stall\ncontrol-use stall"] -.->|stall| IF
    HAZ -.->|stall| ID
    INT["Interrupt Check\next_mip_q | mip_q & mie_q"] -.->|flush| WB
```

### Stage Responsibilities

| Stage | Key operations |
|-------|---------------|
| **IF** | Drive `pc_q` to instruction memory; latch `imem_rdata_q` pre-populated by the harness |
| **ID** | Decode opcode into `ctrl_sig_t`; read two register operands; detect and resolve hazards |
| **EX** | Integer ALU, branch condition, JALR address, CSR read value forwarded to WB |
| **MEM** | Load/store byte-lane alignment; AMO read-modify-write; page-fault detection; store commit |
| **WB** | Write result to `regs_q[]`; dispatch exceptions to CSR state; redirect PC on trap/mret/sret |

---

## Privilege and Trap Flow

```mermaid
stateDiagram-v2
    [*] --> M_mode : reset (PRIV_LVL_M)
    M_mode --> M_mode : ecall (cause 11), mret
    M_mode --> S_mode : mret when mstatus.MPP = S
    S_mode --> M_mode : exception / interrupt not delegated (medeleg/mideleg)
    S_mode --> S_mode : ecall (cause 9), sret, delegated interrupt
    S_mode --> U_mode : sret when mstatus.SPP = U
    U_mode --> S_mode : ecall (cause 8), delegated exception
    U_mode --> M_mode : non-delegated exception
```

**Delegation rule:** if `medeleg[cause]` (exceptions) or `mideleg[cause]` (interrupts) is set and the current privilege is ≤ S, the trap is taken to S-mode using `stvec/sepc/scause`. Otherwise it always goes to M-mode.

**Interrupt priority:** MTI (bit 7) > MSI (bit 3) > STIP (bit 5) > SSIP (bit 1) > MEI (bit 11).  
Interrupts fire at WB before any instruction retires, so they are taken precisely at the current instruction boundary.

---

## Virtual Memory — Sv39

When `satp[63:60] == 4'h8` and the privilege level is ≤ S, all instruction fetches and data accesses use Sv39 three-level page table translation.

```mermaid
graph TD
    VA["Virtual Address\n[38:30] VPN[2]\n[29:21] VPN[1]\n[20:12] VPN[0]\n[11:0]  page offset"] --> TLB

    TLB{"TLB hit?\n(4-entry FA)"}
    TLB -->|hit| PA["Physical Address\nPPN || offset"]
    TLB -->|miss| L2["Load PTE at\nsatp.PPN×4096 + VPN[2]×8"]
    L2 --> L1["Load PTE at\nPTE.PPN×4096 + VPN[1]×8"]
    L1 --> L0["Load PTE at\nPTE.PPN×4096 + VPN[0]×8"]
    L0 --> FILL["Fill TLB entry\ncheck R/W/X/U bits"]
    FILL --> PA

    PA --> PERM{"Permission\ncheck"}
    PERM -->|ok| MEM["Memory access"]
    PERM -->|fail| PF["Page fault\ncause 12/13/15"]
```

**Implementation note:** The page table walker lives entirely in the C++ simulation harness (`sim/sim_main.cpp`), not in the Anvil RTL. This avoids the ~14 GB peak RSS that the Anvil OCaml elaborator hits when compiling wide comparator trees. The harness writes pre-translated physical addresses into `sv39_if_pa_q` / `sv39_mem_pa_q` before each clock edge; the RTL just reads those registers.

---

## xv6 Boot Sequence

```mermaid
sequenceDiagram
    participant HW as Hardware (M-mode)
    participant K  as xv6 Kernel (S-mode)
    participant U  as User Process (U-mode)

    HW->>HW: start(): configure PMP, medeleg, mideleg
    HW->>HW: mret → jump to main() in S-mode
    K->>K: kinit(), kvminit(), kvminithart()
    K->>K: userinit(): create proc[0] with initcode
    K->>K: scheduler() loop
    K->>U: sret → run initcode (exec "/init")
    U->>K: ecall SYS_exec ("/init")
    K->>K: exec() loads /init from virtio-blk disk
    K->>U: sret → run /init
    U->>U: printf("init: starting sh\n")
    U->>K: write() → UART TX → UART IRQ → wakeup
    U->>K: fork() + exec("sh")
    K->>U: sret → run sh
    U->>U: sh prints "$"
```

---

## Repository Layout

```
RISCy-Experiment/
├── src/
│   ├── types/               # Shared HDL type definitions (.anvilh headers)
│   │   ├── pipeline.anvilh  # Packet structs for each pipeline stage boundary
│   │   ├── riscv.anvilh     # CSR addresses, privilege levels, mstatus layout
│   │   ├── capstone.anvilh  # Capability type (future Capstone extension)
│   │   └── channels.anvilh  # Channel type aliases
│   └── core/
│       ├── top/             # Top-level pipeline proc (the entry point for Anvil)
│       │   ├── pipeline_core.anvil   # 5-stage pipeline, trap/interrupt dispatch
│       │   └── packet_utils.anvil    # Bubble/NOP constructors, zero_cap helper
│       ├── decode/          # Instruction decode helpers
│       │   ├── ctrl.anvil   # Opcode → control signal table
│       │   ├── fields.anvil # Instruction field extraction (rs1/rs2/rd/funct3…)
│       │   └── immgen.anvil # Immediate sign-extension for all encoding formats
│       ├── execute/         # Execution units
│       │   ├── alu.anvil    # RV64I integer ALU + W-ops + MUL/DIV/REM
│       │   ├── branch.anvil # Branch condition evaluation
│       │   └── cap_alu.anvil# Capstone capability ALU (future extension)
│       ├── csr/
│       │   └── csr_state.anvil  # M/S-mode CSR state, trap/return helper functions
│       ├── hazard/
│       │   ├── hazard.anvil     # Stall signal generation (load-use, control-use)
│       │   └── forward.anvil    # EX→ID and MEM→ID bypass multiplexers
│       ├── fetch/
│       │   └── imem.anvil       # Instruction memory read (thin wrapper)
│       ├── memory/
│       │   └── mem_stage.anvil  # MEM stage: load sign-extension, store commit
│       └── writeback/
│           └── wb.anvil         # Writeback value selector (load vs ALU result)
├── sim/
│   ├── sim_main.cpp   # Verilator harness: ELF loader, MMIO, Sv39 PTW, CLINT, PLIC
│   ├── startup.S      # Minimal CRT for freestanding C++ program tests
│   └── link.ld        # Linker script: program entry at 0x80000000
├── scripts/
│   ├── build.sh              # Anvil → SystemVerilog → Verilator → binary
│   ├── build_program_sim.sh  # Rebuild the ELF-loading simulator
│   ├── run_riscv_tests.sh    # Run all 58 ISA regression tests
│   ├── run_program.sh        # Run a single C++ program test
│   ├── run_program_trace.sh  # Run with pipeline trace output
│   └── compile_program.sh    # Compile a .cpp file to RISC-V ELF
└── tests/
    ├── isa/             # 58 RISC-V ISA assembly tests (RV64I + M + privilege + Sv39)
    │   ├── env/         # RISC-V test environment header (riscv_test.h)
    │   └── macros/      # Test assertion macros (test_macros.h)
    └── programs/        # Small freestanding C++ smoke tests
```

---

## Building and Running

### Prerequisites

- [Anvil HDL compiler](https://github.com/project-starch/Anvil-Experimental)
- `verilator` ≥ 4.2
- `clang++` with `lld` (or `riscv64-unknown-elf-g++`)
- `opam` switch at `/home/omar/anvil-exp-5.2` (or set `ANVIL_BIN`)

### Quick start

```bash
# Full build: Anvil → Verilator → binary
scripts/build_program_sim.sh

# Run ISA regression (58 tests, ~2 min)
SIM_BIN=build/pipeline_core/obj_dir/Vpipeline_core scripts/run_riscv_tests.sh

# Boot xv6 (requires xv6-riscv built with NCPU=1, PHYSTOP=0x80800000)
build/pipeline_core/obj_dir/Vpipeline_core \
    /path/to/xv6-riscv/kernel/kernel 30000000 \
    --disk /path/to/xv6-riscv/fs.img
```

### Build a single Anvil module

```bash
scripts/build.sh src/core/top/pipeline_core.anvil pipeline_core
```

**Note:** Anvil builds are memory-intensive. If you hit OOM, prefix with:
```bash
ulimit -v $((12 * 1024 * 1024)) && scripts/build.sh ...
```

---

## Toolchain Details

| Tool | Version used | Notes |
|------|-------------|-------|
| Anvil | experimental | Custom HDL; `.anvil` → `.sv` |
| Verilator | ≥ 4.2 | `-O0 -disable-lt-checks` flags for pipeline_core |
| clang++ | system | Test ELF compilation target `riscv64-unknown-elf` |
| riscv64-unknown-elf-gcc | xv6 build | Kernel compilation |

---

## Implementation Status

| Feature | Status |
|---------|--------|
| RV64I base ISA | ✅ Complete (58/58 tests pass) |
| RV64M multiply/divide | ✅ Complete |
| M-mode traps (ecall, ebreak, exceptions) | ✅ Complete |
| S-mode (stvec, sepc, scause, sret) | ✅ Complete |
| Sv39 virtual memory | ✅ Complete (harness-assisted PTW) |
| Timer interrupt (MTIP, STIP) | ✅ Complete |
| xv6-riscv boot to shell | ✅ Complete |
| RV64A atomics (AMO) | ✅ Complete |
| FPGA synthesis | 🔲 Not started |
| Capstone capability extension | 🔲 Scaffolding only |

---

## Roadmap

1. ✅ RV64I + M-mode traps
2. ✅ S-mode + Sv39 paging
3. ✅ Boot xv6-riscv
4. 🔲 FPGA hardening (real BRAM, UART RTL, CLINT RTL, timing closure)
5. 🔲 Capstone: capability domains, transitions, revocation
