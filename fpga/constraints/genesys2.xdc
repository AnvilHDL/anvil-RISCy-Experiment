## RISCy Genesys 2 constraints
## Board: Digilent Genesys 2, Xilinx Kintex-7 XC7K325T-2FFG900C
##
## Pin selections follow the public Genesys 2/CVA6-style constraints:
## - 200 MHz differential system clock: AD12/AD11
## - CPU reset button: R19
## - USB UART: RX Y20, TX Y23
## - User LEDs: T28, V19, U30, U29, V20, V26, W24, W23

set_property -dict { PACKAGE_PIN AD12 IOSTANDARD LVDS } [get_ports { clk200_p }]
set_property -dict { PACKAGE_PIN AD11 IOSTANDARD LVDS } [get_ports { clk200_n }]
create_clock -period 5.000 -name clk200 [get_ports clk200_p]
create_generated_clock -name clk_core -source [get_pins i_coreclk_mmcm/CLKIN1] -divide_by 8 [get_pins i_coreclk_bufg/O]

set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports { cpu_resetn }]
set_false_path -from [get_ports { cpu_resetn }]

set_property -dict { PACKAGE_PIN Y20 IOSTANDARD LVCMOS33 } [get_ports { rx }]
set_property -dict { PACKAGE_PIN Y23 IOSTANDARD LVCMOS33 } [get_ports { tx }]
set_false_path -from [get_ports { rx }]
set_false_path -to [get_ports { tx }]

set_property -dict { PACKAGE_PIN T28 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN V19 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN U30 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN U29 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]
set_property -dict { PACKAGE_PIN V20 IOSTANDARD LVCMOS33 } [get_ports { led[4] }]
set_property -dict { PACKAGE_PIN V26 IOSTANDARD LVCMOS33 } [get_ports { led[5] }]
set_property -dict { PACKAGE_PIN W24 IOSTANDARD LVCMOS33 } [get_ports { led[6] }]
set_property -dict { PACKAGE_PIN W23 IOSTANDARD LVCMOS33 } [get_ports { led[7] }]

set_property -dict { PACKAGE_PIN W19 IOSTANDARD LVCMOS33 } [get_ports { fan_pwm }]
