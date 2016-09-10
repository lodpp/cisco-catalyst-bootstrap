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

# Open a CLI session - it will request a free VTY line available
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

# Lets find the actual image path - usually at the root of flash: but could be
# in a sub-directory.
# If we don't need to change the running image, the script won't touch the path
# If we need to update the image, I will put it at the root of flash: because it's easier 
action_syslog msg "AUTOCONF: Getting Image Path Location"
if { ! [regexp {System image file is "([^:]+:[^"]+)"} $result -> imagepath] } { ;#"
    puts "ERROR: Failed to find system image file in '$result'"
    exit 1
}
action_syslog msg "AUTOCONF: Image Path is: '$imagepath'"  

# Let's work on image file and get the image filename and the image directory
set fstype {flash:}
set rawimagef [file tail $imagepath]
action_syslog msg "AUTOCONF: raw image file is: '$rawimagef'" 
set imaged [file dirname $imagepath]
action_syslog msg "AUTOCONF: image dir is: '$imaged'" 
regexp {([^:]+:)} $imagepath -> fstype


# From the PID, set the correct image to download

# Note :
# I put the smartness to find the correct image ( and md5 ) in the TCL as a starting point,
# but it's against my will to get a bootstrap script as light as possible, anyway it works :)
set image {}
set imagemd5 {}

# The 'switch' conditional command is perfect at matching the image against the pid :)
switch -regexp $pid {
  "WS-C3560X" {
    set image {c3560e-universalk9-mz.150-2.SE10.bin}
    set imagemd5 {d8c599ebcb365d70c7c97c9f3055b609}
  }
  "WS-C3560CX" {
    set image {c3560cx-universalk9-mz.152-3.E3.bin}
    set imagemd5 {a109039eb9e8b4870dfe1df2485c775e}
  }
  default {
    puts "ERROR: Failed to find the corresponding image to use with '$pid'"
    exit 1
  }
}
action_syslog msg "AUTOCONF: Image to use is: '$image' with md5: '$imagemd5'"

# Download the new image if needed
if { [string compare $image $rawimagef] == 0 } {
  action_syslog msg "AUTOCONF: The Switch is already on the correct image '$image'"
} else { 
  action_syslog msg "AUTOCONF: The image needs to be upgraded from '$rawimagef' to '$image'"

  action_syslog msg "AUTOCONF: Downloading Image"
  if { [catch {cli_exec $cli(fd) "copy $TFTP_URL/image/ios/$image $fstype"} result] } {
    error $result $errorInfo
  }
  if { [regexp {"bytes copied in"} $result] } {                                                                           
    action_syslog msg "AUTOCONF: Image Downloaded"
  } else {
    action_syslog msg "AUTOCONF: Unable to fetch the image '$image' at '$TFTP_URL/image/ios/$image'"
    exit 1
  }

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

  # Set the bootvar for the image
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
}


# Download the provisionned config in the startup config
#( not the running - as we may not run the good IOS, some config might not be applied )
# and then, a config from a fresh boot is always better
set config $sn.confg
action_syslog msg "AUTOCONF: Downloading the config for '$sn' at '$TFTP_URL/configs/$config'"
if { [catch {cli_exec $cli(fd) "copy $TFTP_URL/configs/$config startup-config"} result] } {
        error $result $errorInfo
}
if { [regexp {"bytes copied in"} $result] } {
  action_syslog msg "AUTOCONF: Config for '$sn' saved in startup-config"
} else {
  action_syslog msg "AUTOCONF: Unable to fetch the config for '$sn' at '$TFTP_URL/configs/$config'"
  action_syslog msg "AUTOCONF: Will continue in an endless power-cycle ZTP loop until I found my config"
}

action_syslog msg "AUTOCONF COMPLETE: Switch is ready, go for a reload in 10secs"

# Clean close VTY session
# Always put a sleep X sec ( in tcl 'after XX' where X is in msec )
# The box can exec the tcl faster than processing the syslogs.. 
after 5000
catch {cli_close $cli(fd) $cli(tty_id)}
after 5000
action_reload
