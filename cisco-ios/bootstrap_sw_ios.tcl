::cisco::eem::description "This policy bootstraps a switch using the serial number and PID parameters"
::cisco::eem::event_register_appl tag timer sub_system 798 type 1 maxrun 18000 
::cisco::eem::event_register_none tag none
::cisco::eem::trigger {
    ::cisco::eem::correlate event timer or event none
}

namespace import ::cisco::eem::*
namespace import ::cisco::lib::*

action_syslog msg "AUTOCONF: STARTING"

# CHANGE ME to the tftp Address !!!
set ZTP_IP {10.10.66.2}

set TFTP_URL "tftp://$ZTP_IP"

# Found on a cisco script using http request a lot to get info # need to reverse what is the purpose of the init
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

# open a CLI session - it will request a free VTY line available
# during provisionning, wild guess nobody will be on the switch
if { [catch {cli_open} result] } {
    error $result $errorInfo
}

array set cli $result

# Default: you are not ENABLE on the switch so let's do it :)
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
action_syslog msg "AUTOCONF: my PID is: '$pid'"


action_syslog msg "AUTOCONF: Getting SN"    
if { ! [regexp {SN: (\S+)} $result -> sn] } {
    puts "ERROR: Failed to find SN in '$result'"
    exit 1
}
action_syslog msg "AUTOCONF: my SN is: '$sn'"

# Fetching the running version of the switch and the image location
if { [catch {cli_exec $cli(fd) "show version"} result] } {
    error $result $errorInfo
}

action_syslog msg "AUTOCONF: Getting Running Version" 
if { ! [regexp {Version ([^,]+),} $result -> vers] } {
    puts "ERROR: Failed to find version in '$result'"
    exit 1
}
action_syslog msg "AUTOCONF: Running Version is: '$vers'"  

# most probably, the file path will be at the root of flash:
action_syslog msg "AUTOCONF: Getting Image Path Location"
if { ! [regexp {System image file is "([^:]+:[^"]+)"} $result -> imagepath] } { ;#"
    puts "ERROR: Failed to find system image file in '$result'"
    exit 1
}
action_syslog msg "AUTOCONF: Image Path is: '$imagepath'"  

# lets work on image file
set fstype {flash:}
set rawimagef [file tail $imagepath]
action_syslog msg "AUTOCONF: raw image file is: '$rawimagef'" 
set imaged [file dirname $imagepath]
action_syslog msg "AUTOCONF: image dir is: '$imaged'" 
regexp {([^:]+:)} $imagepath -> fstype


# From the PID, set the correct image to download
set image {}
set imagemd5 {}

# I put the smartness to find the correct image ( and md5 ) in the TCL, but it should be somewhere else
# to keep the TCL as light as possible ( and avoid modification , so avoid testing after each modif )
# anyway it works :)
if { [regexp {WS-C3560X} $pid]} {
## c3560e-universalk9-mz.150-1.SE
#  set image {c3560e-universalk9-mz.150-1.SE.bin}
#  set imagemd5 {32333e40e3819a1de4d5aa48f8e7bcef}

## c3560e-universalk9-mz.150-2.SE10
  set image {c3560e-universalk9-mz.150-2.SE10.bin}
  set imagemd5 {d8c599ebcb365d70c7c97c9f3055b609}
  action_syslog msg "AUTOCONF: Image to use is: '$image' with md5: '$imagemd5'"
} else {
    puts "ERROR: Failed to find the corresponding image to use with '$pid'"
    exit 1
}

# Download the new image
action_syslog msg "AUTOCONF: Downloading Image"
if { [catch {cli_exec $cli(fd) "copy $TFTP_URL/image/ios/$image $fstype"} result] } {
  error $result $errorInfo
}
action_syslog msg "AUTOCONF: Image Downloaded"

# md5 check
action_syslog msg "AUTOCONF: Computing MD5 Image '$fstype$image' with md5 '$imagemd5'"
if { [catch {cli_exec $cli(fd) "verify /md5 $fstype$image $imagemd5"} result] } {
  error $result $errorInfo
}

#The output will show a 'Verified' if the md5 given in args match the result
if { [regexp {Verified} $result] } {
  action_syslog msg "AUTOCONF: The md5 check is okay"
} else { 
  action_syslog msg "AUTOCONF: The md5 check failed - the image might be corrupted"
  puts "ERROR: The MD5 of the downloaded image is not the one that it should be, do you download your img from torrent :) ?"
  exit 1
}

# Download the provisionned config in the startup config
#( not the running - as we may not run the good IOS, some config migth not be applied )
# and then, a fresh boot is always good :)
action_syslog msg "AUTOCONF: Downloading the config for '$sn' at '$TFTP_URL/configs/FDxxxxxxxxF.confg
'"
set config $sn.confg
if { [catch {cli_exec $cli(fd) "copy $TFTP_URL/configs/$config startup-config"} result] } {
        error $result $errorInfo
}
action_syslog msg "AUTOCONF: Config for '$sn' saved in startup-config"

action_syslog msg "AUTOCONF: Setting BOOTVAR"
if { $image != {} } {
    if { [catch {cli_exec $cli(fd) "config terminal"} result] } {
        error $result $errorInfo
    }

    if { [catch {cli_exec $cli(fd) "boot system $fstype$image"} result] } {
        error $result $errorInfo
    }

    if { [catch {cli_exec $cli(fd) "end"} result] } {
        error $result $errorInfo
    }
}
action_syslog msg "AUTOCONF: BOOTVAR set"

action_syslog msg "AUTOCONF COMPLETE: Switch is ready, go for a reload in 10secs"

# Close VTY session
# Always put a sleep X sec ( in tcl 'after XX' where X is in msec
# without it, you can miss syslogs, so you might that all the step are not completed but yes they are
after 5000
catch {cli_close $cli(fd) $cli(tty_id)}
after 5000
action_reload
