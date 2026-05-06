open_hw_manager
connect_hw_server
open_hw_target [lindex [get_hw_targets] 0]
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device [current_hw_device]
set_property PROGRAM.FILE [lindex $argv 0] [current_hw_device]
program_hw_devices [current_hw_device]
puts "INFO: Programming complete: [lindex $argv 0]"
close_hw_target
close_hw_manager
