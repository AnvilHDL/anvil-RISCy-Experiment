set bit_file [lindex $argv 0]
set hw_server_url [lindex $argv 1]

if {$bit_file eq ""} {
  error "usage: program_bram_genesys2.tcl <bit_file> ?hw_server_url?"
}
if {$hw_server_url eq ""} {
  set hw_server_url "localhost:3121"
}
if {![file exists $bit_file]} {
  error "bitstream does not exist: $bit_file"
}

open_hw_manager
connect_hw_server -url $hw_server_url
open_hw_target

set device [get_hw_devices -quiet xc7k325t_0]
if {[llength $device] == 0} {
  set device [get_hw_devices -quiet *xc7k325t*]
}
if {[llength $device] == 0} {
  error "no XC7K325T Genesys 2 device found on hardware target"
}
set device [lindex $device 0]

current_hw_device $device
set_property PROGRAM.FILE $bit_file $device
program_hw_devices $device
refresh_hw_device $device

puts "Programmed $device with $bit_file"
