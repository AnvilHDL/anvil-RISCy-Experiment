set root_dir [lindex $argv 0]
set build_dir [lindex $argv 1]
set jobs [lindex $argv 2]

if {$root_dir eq "" || $build_dir eq ""} {
  error "usage: vivado_bitstream_bram_genesys2.tcl <root_dir> <build_dir> <jobs>"
}
if {$jobs eq ""} {
  set jobs 4
}
if {![string is integer -strict $jobs] || $jobs < 1} {
  error "jobs must be a positive integer, got '$jobs'"
}
set_param general.maxThreads $jobs

set part_name "xc7k325tffg900-2"
set board_part "digilentinc.com:genesys2:part0:1.1"
set top_name "risky_genesys2_bram_top"
set project_name "risky_genesys2_bram"
set filelist "$root_dir/build/fpga/risky_genesys2_bram.f"
set xdc_file "$root_dir/fpga/constraints/genesys2.xdc"

if {![file exists $filelist]} {
  error "missing FPGA BRAM filelist: $filelist; run scripts/export_fpga_bram_rtl.sh first"
}
if {![file exists $xdc_file]} {
  error "missing Genesys 2 constraints: $xdc_file"
}

file mkdir $build_dir
file mkdir "$build_dir/reports"
create_project -force $project_name "$build_dir/project" -part $part_name
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

if {[catch {set_property board_part $board_part [current_project]} err]} {
  puts "WARNING: could not set board_part '$board_part': $err"
  puts "WARNING: continuing with explicit part and XDC constraints"
}

set fp [open $filelist r]
set rtl_files {}
while {[gets $fp line] >= 0} {
  set path [string trim $line]
  if {$path ne ""} {
    if {![file exists $path]} {
      error "RTL file from filelist does not exist: $path"
    }
    lappend rtl_files $path
  }
}
close $fp
if {[llength $rtl_files] == 0} {
  error "empty FPGA BRAM filelist: $filelist"
}

read_verilog -sv $rtl_files
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
  puts "WARNING: phys_opt_design skipped or failed: $err"
}
route_design -directive RuntimeOptimized

report_timing_summary -file "$build_dir/reports/post_route_timing_summary.rpt"
report_timing -max_paths 50 -nworst 50 -sort_by slack -file "$build_dir/reports/post_route_timing_worst_50.rpt"
report_utilization -hierarchical -file "$build_dir/reports/post_route_utilization.rpt"
report_clock_interaction -file "$build_dir/reports/clock_interaction.rpt"
report_drc -file "$build_dir/reports/post_route_drc.rpt"

set setup_paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
set hold_paths [get_timing_paths -max_paths 1 -nworst 1 -hold]
set worst_setup_slack 0.0
set worst_hold_slack 0.0
if {[llength $setup_paths] > 0} {
  set worst_setup_slack [get_property SLACK [lindex $setup_paths 0]]
}
if {[llength $hold_paths] > 0} {
  set worst_hold_slack [get_property SLACK [lindex $hold_paths 0]]
}
puts "Post-route timing guard: WNS=$worst_setup_slack WHS=$worst_hold_slack"
if {$worst_setup_slack < 0.0 || $worst_hold_slack < 0.0} {
  error "timing not met: WNS=$worst_setup_slack WHS=$worst_hold_slack"
}

write_checkpoint -force "$build_dir/post_route.dcp"
write_bitstream -force "$build_dir/${project_name}.bit"

puts "Genesys 2 BRAM bitstream written to $build_dir/${project_name}.bit"
