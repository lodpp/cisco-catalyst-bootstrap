::cisco::eem::description "This policy bootstraps a switch using the serial number and PID parameters"
::cisco::eem::event_register_appl tag timer sub_system 798 type 1 maxrun 2400
::cisco::eem::event_register_none tag none
::cisco::eem::trigger {
    ::cisco::eem::correlate event timer or event none
}

namespace import ::cisco::eem::*
namespace import ::cisco::lib::*
#namespace import ::http::*

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

# Compare the requested image VS the the running image
# Download the new one if needed 
if { [regexp {$image} $imagepath ] } {
  action_syslog msg "AUTOCONF: The Running Image fits the Needed Image - We Do Not Need To Upgrade"
} else {
  action_syslog msg "AUTOCONF: We need to upgrade the image"

  # Download itself
  action_syslog msg "AUTOCONF: Downloading Image"
  if { [catch {cli_exec $cli(fd) "copy $TFTP_URL/image/ios/$image $fstype"} result] } {
    error $result $errorInfo
  }
  action_syslog msg "AUTOCONF: Image Downloaded"

  # md5 check
  action_syslog msg "AUTOCONF: Computing MD5 Image '$fstype$image'"
  if { [catch {cli_exec $cli(fd) "verify /md5 $fstype$image"} result] } {
    error $result $errorInfo
  }
  regexp {= ([A-Fa-f0-9]+)} $result -> computedmd5
  action_syslog msg "AUTOCONF: MD5 computed: '$computedmd5'"

  # Comparing computed md5 with provided md5
  action_syslog msg "AUTOCONF: Comparing computed md5 with the known md5"
  set compare [string compare $computedmd5 $imagemd5]

  # 0 = string are the same, 1 or -1 indicates a difference
  if { $compare != 0 } {
    action_syslog msg "AUTOCONF: The md5 check failed - the image might be corrupted"
    puts "ERROR: The MD5 of the downloaded image is not the one that it should be, do you download your img from torrent :) ?"
    exit 1
  } else {
    action_syslog msg "AUTOCONF: The md5 check is okay"
  }
}

# Download the provisionned config in the startup config
#( not the running - as we may not run the good IOS, some config migth not be applied )
# and then, a fresh boot is always good :)
set config $sn.confg

if { [catch {cli_exec $cli(fd) "copy $TFTP_URL/device-configs/$config startup config"} result] } {
        error $result $errorInfo
}


# loop reboot if the switch is not registered
#if { $image == {} && $config == {} } {
#    puts "Switch not registered; rebooting..."
#    after 60000
#    action_reload
#}
action_syslog msg "AUTOCONF: Setting BOOTVAR"
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
}
action_syslog msg "AUTOCONF: BOOTVAR set"

# Close VTY session
catch {cli_close $cli(fd) $cli(tty_id)}

action_syslog msg "AUTOCONF COMPLETE: Switch is ready, go for a reload"

action_reload
