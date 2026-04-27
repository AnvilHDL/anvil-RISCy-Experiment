# scripts/ — Build and Test Scripts

| Script | Purpose |
|--------|---------|
| `build.sh` | Core build: Anvil → SystemVerilog → Verilator → binary |
| `build_program_sim.sh` | Rebuild the ELF-loading simulator (calls `build.sh`) |
| `compile_program.sh` | Compile a single `.cpp` file to a RISC-V ELF for testing |
| `run_riscv_tests.sh` | Compile and run all 58 ISA assembly tests |
| `run_program.sh` | Compile and run a single C++ program test |
| `run_program_trace.sh` | Like `run_program.sh` but with pipeline trace output |

## Typical workflow

```bash
# 1. After changing any .anvil file: full rebuild (~5 min due to Verilator)
scripts/build_program_sim.sh

# 2. Verify correctness
SIM_BIN=build/pipeline_core/obj_dir/Vpipeline_core scripts/run_riscv_tests.sh

# 3. Debug a failing test with trace
build/pipeline_core/obj_dir/Vpipeline_core tests/isa/add.elf 10000 2>&1 | less
```

## Environment variables

| Variable | Default | Effect |
|----------|---------|--------|
| `ANVIL_BIN` | `anvil` | Path to the Anvil compiler binary |
| `ANVIL_FLAGS` | (auto) | Extra flags passed to Anvil (`-O 0 -disable-lt-checks` for pipeline_core) |
| `BUILD_NAME` | top module name | Output directory name under `build/` |
| `SIM_MAIN` | `sim/sim_main.cpp` | Harness source file for the Verilator driver |
| `SIM_BIN` | (built by `build_program_sim.sh`) | Path to the simulator binary for test scripts |
