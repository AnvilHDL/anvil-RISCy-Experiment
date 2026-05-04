ROOT := ..
FPGA_OUT_DIR ?= $(ROOT)/build/fpga/rtl
FPGA_BUILD_DIR ?= $(ROOT)/build/fpga/vivado

.PHONY: help check rtl synth clean

help:
	@echo "Targets:"
	@echo "  make check   - check Genesys 2 FPGA tool prerequisites"
	@echo "  make rtl     - export bounded Anvil-generated RTL for FPGA"
	@echo "  make synth   - run Vivado synthesis smoke for Genesys 2"
	@echo "  make clean   - remove FPGA build outputs"

check:
	@./scripts/check_genesys2_prereqs.sh

rtl:
	@FPGA_OUT_DIR="$(FPGA_OUT_DIR)" "$(ROOT)/scripts/export_fpga_rtl.sh"

synth: rtl
	@FPGA_BUILD_DIR="$(FPGA_BUILD_DIR)" ./scripts/run_vivado_synth.sh

clean:
	@rm -rf "$(ROOT)/build/fpga"
