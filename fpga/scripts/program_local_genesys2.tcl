set bit_file [lindex $argv 0]
if {$bit_file eq ""} {
  error "usage: program_local_genesys2.tcl <bit_file>"
}
if {![file exists $bit_file]} {
  error "bitstream does not exist: $bit_file"
}

set hw_server_url "localhost:3121"

open_hw_manager
connect_hw_server -url $hw_server_url

set target_open 0
set device {}
for {set attempt 1} {$attempt <= 8} {incr attempt} {
  catch {close_hw_target}
  catch {disconnect_hw_server}
  after 1000
  if {[catch {connect_hw_server -url $hw_server_url} err]} {
    puts "WARNING: connect_hw_server attempt $attempt failed: $err"
    after 2000
    continue
  }
  catch {refresh_hw_server}

  set targets [get_hw_targets -quiet]
  if {[llength $targets] == 0} {
    puts "WARNING: no hw targets detected on attempt $attempt; retrying"
    after 2000
    continue
  }

  set target [lindex $targets 0]
  if {[catch {open_hw_target $target} err]} {
    puts "WARNING: open_hw_target attempt $attempt failed: $err"
    after 2000
    continue
  }

  set device_list [get_hw_devices -quiet]
  if {[llength $device_list] > 0} {
    set device [lindex $device_list 0]
    set target_open 1
    break
  }

  puts "WARNING: no devices detected on attempt $attempt; retrying"
  after 2000
}

if {!$target_open} {
  close_hw_manager
  error "no devices detected on the Genesys 2 after 8 attempts"
}

current_hw_device $device
refresh_hw_device $device
set_property PROGRAM.FILE $bit_file $device
program_hw_devices $device
refresh_hw_device $device
puts "INFO: Programming complete: $bit_file"
close_hw_target
close_hw_manager
