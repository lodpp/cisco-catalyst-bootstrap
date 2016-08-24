::cisco::eem::description "This policy bootstraps a switch using the serial number and PID parameters"
::cisco::eem::event_register_appl tag timer sub_system 798 type 1 maxrun 1800
::cisco::eem::event_register_none tag none
::cisco::eem::trigger {
    ::cisco::eem::correlate event timer or event none
}

namespace import ::cisco::eem::*
namespace import ::cisco::lib::*
namespace import ::http::*

action_syslog msg "AUTOCONF: STARTING"


# CHANGE ME to the tftp Address !!!
set ZTP_IP {10.10.66.2}

set TFTP_URL "tftp://$ZTP_IP"

proc init {} {
    variable map
    variable alphanumeric a-zA-Z0-9
    for {set i 0} {$i <= 256} {incr i} {
        set c [format %c $i]
        if { ! [string match \[$alphanumeric\] $c] } {
            set map($c) %[format %.2x $i]
        }
    }
    array set map { " " + \n %0d%0a }
}
init

proc url_encode {str} {
    variable map
    variable alphanumeric

    regsub -all \[^$alphanumeric\] $str {$map(&)} str
    regsub -all {[][{})\\]\)} $str {\\&} str
    return [subst -nocommand $str]
}

# open a CLI session - it will request a free VTY line available
if { [catch {cli_open} result] } {
    error $result $errorInfo
}

array set cli $result

# Default: you are not ENABLE on the switch
if { [catch {cli_exec $cli(fd) "enable"} result] } {
    error $result $errorInfo
}

# Fetching the PID and SN of the switch
if { [catch {cli_exec $cli(fd) "show inventory"} result] } {
    error $result $errorInfo
}

action_syslog msg "AUTOCONF: Getting PID."

if { ! [regexp {PID: (\S+)} $result -> pid] } {
    puts "ERROR: Failed to find PID in '$result'"
    exit 1
}

action_syslog msg "AUTOCONF: Getting SN"    

if { ! [regexp {SN: (\S+)} $result -> sn] } {
    puts "ERROR: Failed to find SN in '$result'"
    exit 1
}

# Fetching the running version of the switch and the image location
action_syslog msg "AUTOCONF: Getting Running Version"    

if { [catch {cli_exec $cli(fd) "show version"} result] } {
    error $result $errorInfo
}

if { ! [regexp {Version ([^,]+),} $result -> vers] } {
    puts "ERROR: Failed to find version in '$result'"
    exit 1
}

action_syslog msg "AUTOCONF: Getting Image Path Location"
    
if { ! [regexp {System image file is "([^:]+:[^"]+)"} $result -> imagepath] } { ;#"
    puts "ERROR: Failed to find system image file in '$result'"
    exit 1
}

set fstype {flash:}
set rawimagef [file tail $imagepath]
set imaged [file dirname $imagepath]
regexp {([^:]+:)} $imagepath -> fstype

# From the PID, set the correct image to download
set image {}
set config $sn.confg

if { [regexp {WS-C3560X} $pid]} {
  set image {c3560e-universalk9-mz.150-1.SE.bin}
}
else {
  puts "ERROR: Failed to find the corresponding image to use with '$pid'"
  exit 1
}

if { [catch {cli_exec $cli(fd) "copy $TFTP_URL/device-configs/$config start"} result] } {
        error $result $errorInfo
    }


# loop reboot if the switch is not registered
#if { $image == {} && $config == {} } {
#    puts "Switch not registered; rebooting..."
#    after 60000
#    action_reload
#}

# Download the image 
if { $image != {} } {
#    if { [catch {cli_exec $cli(fd) "del /force $imagepath"} result] } {
#        error $result $errorInfo
#    }
#
#    if { $imaged != $fstype } {
#        if { [catch {cli_exec $cli(fd) "del /force /recursive $imaged"} result] } {
#            error $result $errorInfo
#        }
#    }
#
#    if { [catch {cli_exec $cli(fd) "del /force $fstype$rawimagef"} result] } {
#        error $result $errorInfo
#    }

    if { [catch {cli_exec $cli(fd) "copy $TFTP_URL/image/ios/$image $fstype"} result] } {
        error $result $errorInfo
    }
}

# Download the config
if { $config != {} } {
    if { [catch {cli_exec $cli(fd) "copy $TFTP_URL/configs/$config start"} result] } {
        error $result $errorInfo
    }
}

# Check the md5 for the new image prior to boot on it
set md5 {}
set verify_image {}

if { $image != {} } {
    if { [catch {cli_exec $cli(fd) "config t"} result] } {
        error $result $errorInfo
    }

    if { [catch {cli_exec $cli(fd) "boot system $fstype$image"} result] } {
        error $result $errorInfo
    }

    if { [catch {cli_exec $cli(fd) "end"} result] } {
        error $result $errorInfo
    }

    if { [catch {cli_exec $cli(fd) "verify /md5 $fstype$image"} result] } {
    error $result $errorInfo
    }

    regexp {= ([A-Fa-f0-9]+)} $result -> md5
    set verify_image [url_encode $image]
}

catch {cli_close $cli(fd) $cli(tty_id)}

action_syslog msg "AUTOCONF COMPLETE: Switch is ready."
action_reload
