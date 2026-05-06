set root_dir  [lindex $argv 0]
set build_dir [lindex $argv 1]
set jobs      [lindex $argv 2]

if {$root_dir eq "" || $build_dir eq ""} {
  error "usage: vivado_bitstream_ddr_genesys2.tcl <root_dir> <build_dir> <jobs>"
}
if {$jobs eq ""} { set jobs 4 }
set_param general.maxThreads $jobs

set part_name    "xc7k325tffg900-2"
set board_part   "digilentinc.com:genesys2:part0:1.1"
set top_name     "risky_genesys2_ddr_top"
set project_name "risky_genesys2_ddr"
set xdc_file     "$root_dir/fpga/constraints/genesys2_ddr.xdc"

file mkdir $build_dir
file mkdir "$build_dir/reports"
create_project -force $project_name "$build_dir/project" -part $part_name
set_property target_language   Verilog [current_project]
set_property simulator_language Mixed  [current_project]

if {[catch {set_property board_part $board_part [current_project]} err]} {
  puts "WARNING: board_part not set: $err"
}

# ---- Generate MIG IP if not already in build ----
set mig_xci "$build_dir/project/ip/mig_7series_0/mig_7series_0.xci"
if {![file exists $mig_xci]} {
  puts "Generating MIG IP..."
  create_ip -name mig_7series -vendor xilinx.com -library ip -version 4.2 \
            -module_name mig_7series_0 -dir "$build_dir/project/ip"
  # Genesys 2: MT41K256M16 HA-125, 512MB, x16, 400 MHz DDR3
  set_property -dict [list \
    CONFIG.XML_INPUT_FILE     "$root_dir/fpga/ip/mig_genesys2.prj" \
    CONFIG.RESET_BOARD_INTERFACE {Custom} \
    CONFIG.MIG_DONT_TOUCH_PARAM {Custom} \
    CONFIG.BOARD_MIG_PARAM      {Custom} \
  ] [get_ips mig_7series_0]
  generate_target all [get_ips mig_7series_0]
  export_ip_user_files -of_objects [get_ips mig_7series_0] -no_script -sync -force -quiet
} else {
  puts "MIG IP already exists at $mig_xci"
}

# ---- RTL sources ----
set rtl_dir "$root_dir/build/fpga/rtl"
set sv_files [list \
  "$rtl_dir/pipeline_core_bram_if.sv" \
  "$rtl_dir/risky_genesys2_ddr_top.sv" \
  "$rtl_dir/risky_ptw.sv" \
  "$rtl_dir/risky_mem_arbiter.sv" \
  "$rtl_dir/risky_mig_adapter.sv" \
  "$rtl_dir/risky_fpga_peripherals.sv" \
  "$rtl_dir/risky_uart_tx.sv" \
  "$rtl_dir/risky_uart_rx.sv" \
  "$rtl_dir/risky_plic.sv" \
]
foreach f $sv_files {
  if {![file exists $f]} { error "Missing RTL file: $f" }
}
read_verilog -sv $sv_files
read_xdc $xdc_file
set_property top $top_name [current_fileset]
update_compile_order -fileset sources_1

synth_design -top $top_name -part $part_name -flatten_hierarchy rebuilt
write_checkpoint -force "$build_dir/post_synth.dcp"
report_utilization -hierarchical -file "$build_dir/reports/post_synth_utilization.rpt"
report_timing_summary -file "$build_dir/reports/post_synth_timing_summary.rpt"

opt_design
place_design -directive RuntimeOptimized
if {[catch {phys_opt_design -directive Explore} err]} {
  puts "WARNING: phys_opt_design skipped: $err"
}
route_design -directive RuntimeOptimized

report_timing_summary -file "$build_dir/reports/post_route_timing_summary.rpt"
report_timing -max_paths 50 -nworst 50 -sort_by slack \
              -file "$build_dir/reports/post_route_timing_worst_50.rpt"
report_utilization -hierarchical -file "$build_dir/reports/post_route_utilization.rpt"
report_clock_interaction -file "$build_dir/reports/clock_interaction.rpt"
report_drc -file "$build_dir/reports/post_route_drc.rpt"

set setup_paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
set hold_paths  [get_timing_paths -max_paths 1 -nworst 1 -hold]
set wns 0.0
set whs 0.0
if {[llength $setup_paths] > 0} { set wns [get_property SLACK [lindex $setup_paths 0]] }
if {[llength $hold_paths]  > 0} { set whs [get_property SLACK [lindex $hold_paths 0]] }
puts "Post-route timing: WNS=$wns WHS=$whs"
if {$wns < 0.0 || $whs < 0.0} {
  error "Timing not met: WNS=$wns WHS=$whs"
}

write_checkpoint -force "$build_dir/post_route.dcp"
write_bitstream  -force "$build_dir/${project_name}.bit"
puts "DDR3 bitstream: $build_dir/${project_name}.bit"
