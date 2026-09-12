# tests/ — Test Suite

## ISA Tests (`tests/isa/`)

21 RISC-V assembly tests covering:

| Category | Tests |
|----------|-------|
| Integer/core smoke | covered by the C++ program tests and compiled code paths |
| Loads/stores/branches | `misalign_load`, `misalign_store`, plus C++ smoke programs |
| Multiply/divide | `div_rem` |
| Privileged | `ecall_mret`, `ebreak`, `csr`, `sret`, `illegal` |
| Memory exceptions | `misalign_load`, `misalign_store` |
| Virtual memory | `sv39_basic`, `sv39_pagefault` |
| Interrupts | `timer_irq` |
| Experimental capabilities | `cap_*` capability instruction tests |

Each test uses the standard RISC-V test environment (`env/riscv_test.h`, `macros/scalar/test_macros.h`).
A test passes when it writes exit code 0 via `ecall` with `a7 = 93`.

### Running

```bash
# Run all ISA tests
scripts/run_riscv_tests.sh

# Run all C++ program tests
scripts/run_program_tests.sh

# Run the guarded full local verification
scripts/verify_all.sh

# Run one test
build/pipeline_core_program/obj_dir/Vpipeline_core tests/isa/csr.elf 100000
```

## C++ Program Tests (`tests/programs/`)

Small freestanding programs that test the simulator's C++ ABI integration:

| File | What it tests |
|------|--------------|
| `fibonacci.cpp` | Recursive function calls, stack depth |
| `arith.cpp` | Basic arithmetic through the C compiler |
| `branch_loop.cpp` | Loop branches and comparisons |
| `division.cpp` | Compiler-generated DIV/REM instructions |
| `load_store.cpp` | Volatile memory access, global arrays |
| `pipeline_showcase.cpp` | Load-use hazards, forwarding paths |
| `word_ops.cpp` | 32-bit word operations (W-suffix instructions) |
| `hello_regs.cpp` | Register argument passing convention |

These are compiled with `scripts/compile_program.sh`, which prefers
`riscv64-unknown-elf-g++` when available and otherwise falls back to
`clang++ --target=riscv64-unknown-elf`. They use the linker script in
`sim/link.ld` and the startup code in `sim/startup.S`. A program test passes
when `main()` returns 0.
