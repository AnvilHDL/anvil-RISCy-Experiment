# scripts/ — Build and Test Scripts

| Script | Purpose |
|--------|---------|
| `build.sh` | Core build: Anvil → SystemVerilog → Verilator → binary |
| `build_program_sim.sh` | Rebuild the ELF-loading simulator (calls `build.sh`) |
| `export_fpga_rtl.sh` | Bounded Anvil-only RTL export for FPGA flows |
| `compile_program.sh` | Compile a single `.cpp` file to a RISC-V ELF for testing |
| `run_riscv_tests.sh` | Compile and run all ISA assembly tests |
| `run_program_tests.sh` | Compile and run all freestanding C++ program tests |
| `run_program.sh` | Compile and run a single C++ program test |
| `run_program_trace.sh` | Like `run_program.sh` but with pipeline trace output |
| `lint_generated_sv.sh` | Verilator lint for generated SystemVerilog |
| `lint_fpga_rtl.sh` | Export and lint the Genesys 2 FPGA RTL wrapper/core |
| `run_xv6_smoke.sh` | Boot xv6 with explicit kernel/fs image paths and stop once the shell prompt appears |
| `check_fpga_boundary.sh` | Ensure simulation-backed services are documented and stale harness patches stay removed |
| `verify_all.sh` | Guarded build plus ISA and C++ regressions |

## Typical workflow

```bash
# 1. After changing any .anvil file: full rebuild (~5 min due to Verilator)
scripts/build_program_sim.sh

# 2. Verify correctness
scripts/verify_all.sh

# 3. Debug a failing test with trace
build/pipeline_core_program/obj_dir/Vpipeline_core tests/isa/csr.elf 10000 2>&1 | less
```

## Environment variables

| Variable | Default | Effect |
|----------|---------|--------|
| `ANVIL_BIN` | `anvil` | Path to the Anvil compiler binary |
| `ANVIL_FLAGS` | (auto) | Extra flags passed to Anvil (`-O 0 -disable-lt-checks` for pipeline_core) |
| `BUILD_NAME` | top module name | Output directory name under `build/` |
| `SIM_MAIN` | `sim/sim_main.cpp` | Harness source file for the Verilator driver |
| `SIM_BIN` | (built by `build_program_sim.sh`) | Path to the simulator binary for test scripts |
| `ANVIL_VMEM_MB` | `12288` | Virtual-memory cap for the Anvil compiler; set `0` to disable |
| `ANVIL_TIMEOUT` | `20m` | Host timeout for Anvil compilation |
| `FPGA_OUT_DIR` | `build/fpga/rtl` | Output directory for FPGA RTL export |
| `VERILATOR_TIMEOUT` | `30m` | Host timeout for Verilator C++ generation |
| `MAKE_TIMEOUT` | `30m` | Host timeout for the generated simulator build |
| `TEST_COMPILE_TIMEOUT` | `30s` | Per-ISA-test compile timeout |
| `TEST_RUN_TIMEOUT` | `30s` | Per-ISA-test simulator timeout |
| `HOST_TIMEOUT` | `120s` | Host timeout for `run_program*.sh` simulator runs |
| `SIM_CYCLE_LIMIT` | `100000` | Default cycle limit used by `run_program_tests.sh` |
| `VERIFY_BUILD_TIMEOUT` | `20m` | Overall build timeout used by `verify_all.sh` |
| `VERIFY_TEST_TIMEOUT` | `5m` | Overall timeout for each regression phase in `verify_all.sh` |
| `RUN_XV6` | `0` | Set to `1` to include xv6 smoke in `verify_all.sh` |
| `XV6_KERNEL` | (required for xv6) | Path to xv6-riscv `kernel/kernel` ELF |
| `XV6_FS_IMG` | (required for xv6) | Path to xv6-riscv `fs.img` |
| `XV6_CYCLE_LIMIT` | `30000000` | Simulator cycle budget for xv6 smoke |
| `XV6_HOST_TIMEOUT` | `180s` | Host timeout for xv6 smoke |
| `LINT_TIMEOUT` | `2m` | Host timeout for generated SystemVerilog lint |
| `FPGA_LINT_TIMEOUT` | `3m` | Host timeout for FPGA wrapper/core lint |
