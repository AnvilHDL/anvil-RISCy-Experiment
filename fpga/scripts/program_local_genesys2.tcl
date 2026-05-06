set bit_file [lindex $argv 0]
if {$bit_file eq ""} {
  error "usage: program_local_genesys2.tcl <bit_file>"
}
if {![file exists $bit_file]} {
  error "bitstream does not exist: $bit_file"
}

open_hw_manager
connect_hw_server

set target_open 0
set device {}
for {set attempt 1} {$attempt <= 5} {incr attempt} {
  catch {close_hw_target}
  if {[catch {open_hw_target [lindex [get_hw_targets] 0]} err]} {
    puts "WARNING: open_hw_target attempt $attempt failed: $err"
  } else {
    set device_list [get_hw_devices]
    if {[llength $device_list] > 0} {
      set device [lindex $device_list 0]
      set target_open 1
      break
    }
    puts "WARNING: no devices detected on attempt $attempt; retrying"
  }
  after 2000
}

if {!$target_open} {
  close_hw_manager
  error "no devices detected on the Genesys 2 after 5 attempts"
}

current_hw_device $device
refresh_hw_device $device
set_property PROGRAM.FILE $bit_file $device
program_hw_devices $device
refresh_hw_device $device
puts "INFO: Programming complete: $bit_file"
close_hw_target
close_hw_manager
