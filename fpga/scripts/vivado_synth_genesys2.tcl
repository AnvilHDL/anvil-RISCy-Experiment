set root_dir [lindex $argv 0]
set build_dir [lindex $argv 1]
set jobs [lindex $argv 2]

if {$root_dir eq "" || $build_dir eq ""} {
  error "usage: vivado_synth_genesys2.tcl <root_dir> <build_dir> <jobs>"
}
if {$jobs eq ""} {
  set jobs 4
}

set part_name "xc7k325tffg900-2"
set top_name "risky_genesys2_top"
set filelist "$root_dir/build/fpga/risky_genesys2.f"
set xdc_file "$root_dir/fpga/constraints/genesys2.xdc"

if {![file exists $filelist]} {
  error "missing FPGA filelist: $filelist; run scripts/export_fpga_rtl.sh first"
}
if {![file exists $xdc_file]} {
  error "missing Genesys 2 constraints: $xdc_file"
}

file mkdir $build_dir
create_project -force risky_genesys2 $build_dir -part $part_name
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set fp [open $filelist r]
set rtl_files {}
while {[gets $fp line] >= 0} {
  set path [string trim $line]
  if {$path ne ""} {
    lappend rtl_files $path
  }
}
close $fp

read_verilog -sv $rtl_files
read_xdc $xdc_file
set_property top $top_name [current_fileset]

synth_design -top $top_name -part $part_name -flatten_hierarchy rebuilt
report_utilization -file "$build_dir/post_synth_utilization.rpt"
report_timing_summary -file "$build_dir/post_synth_timing.rpt"
write_checkpoint -force "$build_dir/post_synth.dcp"

puts "Genesys 2 synthesis smoke completed"
