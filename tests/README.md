# tests/ — Test Suite

## ISA Tests (`tests/isa/`)

58 RISC-V assembly tests covering:

| Category | Tests |
|----------|-------|
| Integer arithmetic (RV64I + M) | `add`, `addi`, `sub`, `mul`, `div`, `rem`, `mulw`, `divw`, … |
| Bitwise | `and`, `andi`, `or`, `ori`, `xor`, `xori` |
| Shifts | `sll`, `slli`, `srl`, `srli`, `sra`, `srai`, `sllw`, `srlw`, `sraw`, … |
| Loads | `lb`, `lbu`, `lh`, `lhu`, `lw`, `lwu`, `ld` |
| Stores | `sb`, `sh`, `sw`, `sd` |
| Branches | `beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu` |
| Jumps | `jal`, `jalr` |
| Privileged | `ecall_mret`, `ebreak`, `csr`, `sret`, `illegal` |
| Memory exceptions | `misalign_load`, `misalign_store` |
| Virtual memory | `sv39_basic`, `sv39_pagefault` |
| Interrupts | `timer_irq` |

Each test uses the standard RISC-V test environment (`env/riscv_test.h`, `macros/scalar/test_macros.h`).
A test passes when it writes exit code 0 via `ecall` with `a7 = 93`.

### Running

```bash
# Run all 58 tests
SIM_BIN=build/pipeline_core/obj_dir/Vpipeline_core scripts/run_riscv_tests.sh

# Run one test
build/pipeline_core/obj_dir/Vpipeline_core tests/isa/add.elf 100000
```

## C++ Program Tests (`tests/programs/`)

Small freestanding programs that test the simulator's C++ ABI integration:

| File | What it tests |
|------|--------------|
| `fibonacci.cpp` | Recursive function calls, stack depth |
| `arith.cpp` | Basic arithmetic through the C compiler |
| `branch_loop.cpp` | Loop branches and comparisons |
| `load_store.cpp` | Volatile memory access, global arrays |
| `pipeline_showcase.cpp` | Load-use hazards, forwarding paths |
| `word_ops.cpp` | 32-bit word operations (W-suffix instructions) |
| `hello_regs.cpp` | Register argument passing convention |

These are compiled with `clang++ --target=riscv64-unknown-elf` using the
linker script in `sim/link.ld` and the startup code in `sim/startup.S`.
