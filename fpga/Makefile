ROOT := ..
FPGA_OUT_DIR ?= $(ROOT)/build/fpga/rtl
FPGA_BUILD_DIR ?= $(ROOT)/build/fpga/vivado

.PHONY: help check rtl bram bitstream-bram program-bram synth clean

help:
	@echo "Targets:"
	@echo "  make check   - check Genesys 2 FPGA tool prerequisites"
	@echo "  make rtl     - export bounded Anvil-generated RTL for FPGA"
	@echo "  make bram    - export/lint BRAM bare-metal bring-up target"
	@echo "  make bitstream-bram - implement BRAM target and write .bit"
	@echo "  make program-bram   - program local Genesys 2 with BRAM .bit"
	@echo "  make synth   - run Vivado synthesis smoke for Genesys 2"
	@echo "  make clean   - remove FPGA build outputs"

check:
	@./scripts/check_genesys2_prereqs.sh

rtl:
	@FPGA_OUT_DIR="$(FPGA_OUT_DIR)" "$(ROOT)/scripts/export_fpga_rtl.sh"

bram:
	@FPGA_OUT_DIR="$(FPGA_OUT_DIR)" "$(ROOT)/scripts/lint_fpga_bram_rtl.sh"

bitstream-bram:
	@FPGA_OUT_DIR="$(FPGA_OUT_DIR)" FPGA_BUILD_DIR="$(ROOT)/build/fpga/vivado-bram" ./scripts/run_vivado_bram_bitstream.sh

program-bram:
	@BRAM_BITSTREAM="$(ROOT)/build/fpga/vivado-bram/risky_genesys2_bram.bit" ./scripts/program_bram_bitstream.sh

synth: rtl
	@FPGA_BUILD_DIR="$(FPGA_BUILD_DIR)" ./scripts/run_vivado_synth.sh

clean:
	@rm -rf "$(ROOT)/build/fpga"
