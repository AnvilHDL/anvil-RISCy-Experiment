# scripts/

Build, test and export entry points. Scripts use the active shell environment:
put the Anvil compiler in `PATH` or set `ANVIL_BIN` to its executable.

## Top-level entry points

| Script | Purpose |
| --- | --- |
| `run_xv6.sh` | Boot xv6, from a clean checkout, in one command. Initialises the submodule, installs the RISC-V toolchain, builds xv6 and the simulator, then boots. Takes about 7 minutes to reach the shell prompt. `-i` stays attached to the shell. |
| `verify_all.sh` | Full check: shell syntax, FPGA boundary, simulator build, ISA and C++ regressions, SystemVerilog lint, FPGA exports. Adds the xv6 boot when `RUN_XV6=1`. |

## Build

| Script | Purpose |
| --- | --- |
| `build.sh` | Compile one `.anvil` file to SystemVerilog, then to a Verilator binary. Takes the source path and optional top module. |
| `build_program_sim.sh` | Rebuild the ELF-loading simulator from `src/core/top/pipeline_core.anvil`. Wraps `build.sh`. |
| `compile_program.sh` | Compile one C++ file to a freestanding RISC-V ELF. |

## Test

| Script | Purpose |
| --- | --- |
| `run_riscv_tests.sh` | Compile and run every ISA test in `tests/isa/`. |
| `run_program_tests.sh` | Compile and run every C++ program in `tests/programs/`. |
| `run_program.sh` | Compile and run a single C++ program. |
| `run_program_trace.sh` | As `run_program.sh`, with pipeline trace output. |
| `run_xv6_smoke.sh` | Boot xv6 from explicit `XV6_KERNEL` and `XV6_FS_IMG` paths and stop at the shell prompt. Called by `run_xv6.sh`. |

## Lint and FPGA export

| Script | Purpose |
| --- | --- |
| `lint_generated_sv.sh` | Verilator lint of the generated SystemVerilog. |
| `export_fpga_rtl.sh` | Export the core's RTL for the Genesys 2 synthesis target. |
| `export_fpga_bram_rtl.sh` | Export the BRAM-backed bring-up target. |
| `export_fpga_ddr_rtl.sh` | Export the DDR3/MIG integration target. |
| `lint_fpga_rtl.sh` | Export then lint the FPGA wrapper and core. |
| `lint_fpga_bram_rtl.sh` | Export then lint the BRAM target. |
| `gen_fpga_bram_init.py` | Generate BRAM initialisation data from a program image. |
| `check_fpga_boundary.sh` | Check that services the harness supplies stay documented in `docs/WORK_LOG.md`. |

## toolchain/

| Script | Purpose |
| --- | --- |
| `install_riscv_toolchain.sh` | Install a prebuilt `riscv64-unknown-elf` GCC into `.toolchain/`, no root required. |
| `build_xv6.sh` | Build the xv6 submodule for this core's ISA, out of tree into `.toolchain/xv6-build`. |

## Environment variables

| Variable | Applies to | Default |
| --- | --- | --- |
| `ANVIL_BIN` | all builds | `anvil` from `PATH` |
| `ANVIL_VMEM_MB` | `build.sh` | `12288`; `0` disables the limit |
| `ANVIL_TIMEOUT` | `build.sh` | `20m` |
| `XV6_CYCLE_LIMIT` | xv6 boot | `2000000000` in `run_xv6.sh` |
| `XV6_HOST_TIMEOUT` | xv6 boot | `0` (no wall-clock limit) in `run_xv6.sh` |
| `XV6_EXPECTED_BOOT_SECS` | `run_xv6.sh` | `400`; scales the progress bar only |
| `RUN_XV6` | `verify_all.sh` | unset; set to `1` to include the xv6 boot |
