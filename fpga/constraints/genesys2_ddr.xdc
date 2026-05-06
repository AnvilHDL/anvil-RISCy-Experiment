## RISCy Genesys 2 DDR3 constraints
## Board: Digilent Genesys 2, Xilinx Kintex-7 XC7K325T-2FFG900C
## Extends genesys2.xdc with DDR3 pin assignments for Micron MT41K256M16 HA-125

## === System clock, reset, UART (same as BRAM target) ===
set_property -dict { PACKAGE_PIN AD12 IOSTANDARD LVDS } [get_ports { clk200_p }]
set_property -dict { PACKAGE_PIN AD11 IOSTANDARD LVDS } [get_ports { clk200_n }]
create_clock -period 5.000 -name clk200 [get_ports clk200_p]

set_property -dict { PACKAGE_PIN R19  IOSTANDARD LVCMOS33 } [get_ports { cpu_resetn }]
set_false_path -from [get_ports { cpu_resetn }]

set_property -dict { PACKAGE_PIN Y20  IOSTANDARD LVCMOS33 } [get_ports { rx }]
set_property -dict { PACKAGE_PIN Y23  IOSTANDARD LVCMOS33 } [get_ports { tx }]
set_false_path -from [get_ports { rx }]
set_false_path -to   [get_ports { tx }]

set_property -dict { PACKAGE_PIN T28  IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN V19  IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN U30  IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN U29  IOSTANDARD LVCMOS33 } [get_ports { led[3] }]
set_property -dict { PACKAGE_PIN V20  IOSTANDARD LVCMOS33 } [get_ports { led[4] }]
set_property -dict { PACKAGE_PIN V26  IOSTANDARD LVCMOS33 } [get_ports { led[5] }]
set_property -dict { PACKAGE_PIN W24  IOSTANDARD LVCMOS33 } [get_ports { led[6] }]
set_property -dict { PACKAGE_PIN W23  IOSTANDARD LVCMOS33 } [get_ports { led[7] }]

set_property -dict { PACKAGE_PIN W19  IOSTANDARD LVCMOS33 } [get_ports { fan_pwm }]

## === DDR3 — Genesys 2 Micron MT41K256M16 HA-125 (512MB, x16) ===
## Pin mapping from Digilent Genesys 2 Master XDC

set_property -dict { PACKAGE_PIN AB8  IOSTANDARD SSTL15 } [get_ports { ddr3_dq[0]  }]
set_property -dict { PACKAGE_PIN AA8  IOSTANDARD SSTL15 } [get_ports { ddr3_dq[1]  }]
set_property -dict { PACKAGE_PIN AA7  IOSTANDARD SSTL15 } [get_ports { ddr3_dq[2]  }]
set_property -dict { PACKAGE_PIN AB7  IOSTANDARD SSTL15 } [get_ports { ddr3_dq[3]  }]
set_property -dict { PACKAGE_PIN AB9  IOSTANDARD SSTL15 } [get_ports { ddr3_dq[4]  }]
set_property -dict { PACKAGE_PIN AA9  IOSTANDARD SSTL15 } [get_ports { ddr3_dq[5]  }]
set_property -dict { PACKAGE_PIN AB10 IOSTANDARD SSTL15 } [get_ports { ddr3_dq[6]  }]
set_property -dict { PACKAGE_PIN AA10 IOSTANDARD SSTL15 } [get_ports { ddr3_dq[7]  }]
set_property -dict { PACKAGE_PIN Y7   IOSTANDARD SSTL15 } [get_ports { ddr3_dq[8]  }]
set_property -dict { PACKAGE_PIN W7   IOSTANDARD SSTL15 } [get_ports { ddr3_dq[9]  }]
set_property -dict { PACKAGE_PIN W9   IOSTANDARD SSTL15 } [get_ports { ddr3_dq[10] }]
set_property -dict { PACKAGE_PIN V9   IOSTANDARD SSTL15 } [get_ports { ddr3_dq[11] }]
set_property -dict { PACKAGE_PIN W10  IOSTANDARD SSTL15 } [get_ports { ddr3_dq[12] }]
set_property -dict { PACKAGE_PIN V10  IOSTANDARD SSTL15 } [get_ports { ddr3_dq[13] }]
set_property -dict { PACKAGE_PIN Y8   IOSTANDARD SSTL15 } [get_ports { ddr3_dq[14] }]
set_property -dict { PACKAGE_PIN W8   IOSTANDARD SSTL15 } [get_ports { ddr3_dq[15] }]

set_property -dict { PACKAGE_PIN W6   IOSTANDARD DIFF_SSTL15 } [get_ports { ddr3_dqs_p[0] }]
set_property -dict { PACKAGE_PIN W5   IOSTANDARD DIFF_SSTL15 } [get_ports { ddr3_dqs_n[0] }]
set_property -dict { PACKAGE_PIN AA5  IOSTANDARD DIFF_SSTL15 } [get_ports { ddr3_dqs_p[1] }]
set_property -dict { PACKAGE_PIN AB5  IOSTANDARD DIFF_SSTL15 } [get_ports { ddr3_dqs_n[1] }]

set_property -dict { PACKAGE_PIN AA2  IOSTANDARD SSTL15 } [get_ports { ddr3_dm[0] }]
set_property -dict { PACKAGE_PIN Y3   IOSTANDARD SSTL15 } [get_ports { ddr3_dm[1] }]

set_property -dict { PACKAGE_PIN T6   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[0]  }]
set_property -dict { PACKAGE_PIN T5   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[1]  }]
set_property -dict { PACKAGE_PIN U5   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[2]  }]
set_property -dict { PACKAGE_PIN U6   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[3]  }]
set_property -dict { PACKAGE_PIN V7   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[4]  }]
set_property -dict { PACKAGE_PIN V6   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[5]  }]
set_property -dict { PACKAGE_PIN V2   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[6]  }]
set_property -dict { PACKAGE_PIN V3   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[7]  }]
set_property -dict { PACKAGE_PIN U1   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[8]  }]
set_property -dict { PACKAGE_PIN U2   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[9]  }]
set_property -dict { PACKAGE_PIN U3   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[10] }]
set_property -dict { PACKAGE_PIN T4   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[11] }]
set_property -dict { PACKAGE_PIN T3   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[12] }]
set_property -dict { PACKAGE_PIN R3   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[13] }]
set_property -dict { PACKAGE_PIN W4   IOSTANDARD SSTL15 } [get_ports { ddr3_addr[14] }]

set_property -dict { PACKAGE_PIN V4   IOSTANDARD SSTL15 } [get_ports { ddr3_ba[0] }]
set_property -dict { PACKAGE_PIN W3   IOSTANDARD SSTL15 } [get_ports { ddr3_ba[1] }]
set_property -dict { PACKAGE_PIN W1   IOSTANDARD SSTL15 } [get_ports { ddr3_ba[2] }]

set_property -dict { PACKAGE_PIN Y1   IOSTANDARD SSTL15 } [get_ports { ddr3_ras_n  }]
set_property -dict { PACKAGE_PIN T1   IOSTANDARD SSTL15 } [get_ports { ddr3_cas_n  }]
set_property -dict { PACKAGE_PIN R1   IOSTANDARD SSTL15 } [get_ports { ddr3_we_n   }]
set_property -dict { PACKAGE_PIN P1   IOSTANDARD LVCMOS15 } [get_ports { ddr3_reset_n }]

set_property -dict { PACKAGE_PIN U7   IOSTANDARD DIFF_SSTL15 } [get_ports { ddr3_ck_p[0] }]
set_property -dict { PACKAGE_PIN V7   IOSTANDARD DIFF_SSTL15 } [get_ports { ddr3_ck_n[0] }]

set_property -dict { PACKAGE_PIN T2   IOSTANDARD SSTL15 } [get_ports { ddr3_cke[0] }]
set_property -dict { PACKAGE_PIN R2   IOSTANDARD SSTL15 } [get_ports { ddr3_odt[0] }]

## MIG generates its own internal timing constraints via the .prj file.
## Async paths across clock domains (ui_clk → none; all logic on one clock).
set_false_path -from [get_ports { cpu_resetn }]
