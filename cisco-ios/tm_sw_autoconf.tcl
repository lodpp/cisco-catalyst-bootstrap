::cisco::eem::description "This policy bootstraps a switch using the serial number and PID parameters"
::cisco::eem::event_register_appl tag timer sub_system 798 type 1 maxrun 1800
::cisco::eem::event_register_none tag none
::cisco::eem::trigger {
    ::cisco::eem::correlate event timer or event none
}

namespace import ::cisco::eem::*
namespace import ::cisco::lib::*
namespace import ::http::*

# CHANGE ME!!!
set ZTP_IP {ZTP_SERVER_IP}

set URL "http://$ZTP_IP/swreg/swreg.php"
set VERIFY_URL "http://$ZTP_IP/swreg/verify.php"
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


if { [catch {cli_open} result] } {
    error $result $errorInfo
}

array set cli $result

if { [catch {cli_exec $cli(fd) "enable"} result] } {
    error $result $errorInfo
}

if { [catch {cli_exec $cli(fd) "show inventory"} result] } {
    error $result $errorInfo
}

if { ! [regexp {PID: (\S+)} $result -> pid] } {
    puts "ERROR: Failed to find PID in '$result'"
    exit 1
}

if { ! [regexp {SN: (\S+)} $result -> sn] } {
    puts "ERROR: Failed to find SN in '$result'"
    exit 1
}

if { [catch {cli_exec $cli(fd) "show version"} result] } {
    error $result $errorInfo
}

if { ! [regexp {Version ([^,]+),} $result -> vers] } {
    puts "ERROR: Failed to find version in '$result'"
    exit 1
}

if { ! [regexp {System image file is "([^:]+:[^"]+)"} $result -> imagepath] } { ;#"
    puts "ERROR: Failed to find system image file in '$result'"
    exit 1
}

set fstype {flash:}
set rawimagef [file tail $imagepath]
set imaged [file dirname $imagepath]
regexp {([^:]+:)} $imagepath -> fstype

if { [catch {cli_exec $cli(fd) "show ip int brie | include Ethernet"} result] } {
    error $result $errorInfo
}

set intfs 0
foreach line [split $result "\n"] {
    if { [regexp {Ethernet} $line] } {
        incr intfs
    }
}

set vers [url_encode $vers]
set imagef [url_encode $rawimagef]

::http::config -useragent "tm_sw_autoconf.tcl/1.0"
set tok [::http::geturl "$URL?pid=$pid&sn=$sn&version=$vers&num_ports=$intfs&imagef=$imagef"]
if { [::http::error $tok] != "" } {
    puts "ERROR: Failed to retrieve switch info: '[::http::error $tok]'"
    exit 1
}

set image {}
set config {}
set pnp 0

foreach line [split [::http::data $tok] "\n"] {
    if { [regexp {^Image: (\S+)} $line -> res] } {
        set image $res
    }
    if { [regexp {^Config: (\S+)} $line -> res] } {
        set config $res
    }
    if { [regexp {^PNP} $line] } {
	set pnp 1
    }
}

if { $image == {} && $config == {}  && $pnp == 0 } {
    puts "Switch not registered; rebooting..."
    after 60000
    action_reload
}

if { $image != {} } {
    if { [catch {cli_exec $cli(fd) "del /force $imagepath"} result] } {
        error $result $errorInfo
    }

    if { $imaged != $fstype } {
    	if { [catch {cli_exec $cli(fd) "del /force /recursive $imaged"} result] } {
        	error $result $errorInfo
    	}
    }

    if { [catch {cli_exec $cli(fd) "del /force $fstype$rawimagef"} result] } {
        error $result $errorInfo
    }

    if { [catch {cli_exec $cli(fd) "copy $TFTP_URL/$image $fstype"} result] } {
        error $result $errorInfo
    }
}

if { $config != {} } {
    if { [catch {cli_exec $cli(fd) "copy $TFTP_URL/device-configs/$config start"} result] } {
        error $result $errorInfo
    }

    if { [catch {cli_exec $cli(fd) "config t"} result] } {
        error $result $errorInfo
    }

    if { [catch {cli_exec $cli(fd) "sdm prefer vlan"} result] } {
        error $result $errorInfo
    }

    if { [catch {cli_exec $cli(fd) "end"} result] } {
        error $result $errorInfo
    }

    if { [catch {cli_exec $cli(fd) "show switch | inc ^\\*"} result] } {
        error $result $errorInfo
    }

    if { [regexp {\*([2-9])} $result -> swn] } {
        if { [catch {cli_exec $cli(fd) "config t"} result] } {
            error $result $errorInfo
        }

        if { [catch {cli_write $cli(fd) "switch $swn renumber 1"} result] } {
            error $result $errorInfo
        }

        if { [catch {cli_read_pattern $cli(fd) "confirm"} result] } {
            error $result $errorInfo
        }

        if { [catch {cli_exec $cli(fd) "\r"} result] } {
            error $result $errorInfo
        }

        if { [catch {cli_exec $cli(fd) "end"} result] } {
            error $result $errorInfo
        }
    }

    if { [catch {cli_exec $cli(fd) "license right-to-use activate ipservices acceptEULA"} result] } {
        puts "WARNING: Failed to change license: '$result'"
    }
}

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

if { $config != {} || $image != {} } {
    if { $config != {} } {
    	if { [catch {cli_exec $cli(fd) "copy start ${TFTP_URL}/device-tmp/$config"} result] } {
        	error $result $errorInfo
    	}

    	# Wait a max of five seconds for the tftp daemon to flush its write buffer.
    	after 5000
    }

    ::http::config -useragent "tm_sw_autoconf.tcl/1.0"
    set tok [::http::geturl "$VERIFY_URL?config=$config&sn=$sn&md5=$md5&image=$verify_image"]
    if { [::http::error $tok] != "" } {
        puts "ERROR: Failed to verify switch config: '[::http::error $tok]'"
        exit 1
    }

    foreach line [split [::http::data $tok] "\n"] {
        if { [regexp {ERROR:} $line] } {
            action_syslog msg "AUTOCONF FAILED: Bootstrap verification failed: '$line'"
            exit 1
        }
    }

    if { $config != {} } {
    	if { [catch {cli_exec $cli(fd) "config mem"} result] } {
        	error $result $errorInfo
    	}
    }
}

if { $pnp == 1 } {
    if { [catch {cli_exec $cli(fd) "test pnpa discovery process"} result] } {
	error $result $errorInfo
    }

    # At this point, PnP takes over.
    # TODO Need to confirm that the PnP discovery is successful
}

catch {cli_close $cli(fd) $cli(tty_id)}

action_syslog msg "AUTOCONF COMPLETE: Switch is ready."
action_reload
