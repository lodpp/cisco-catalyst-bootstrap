# cisco-catalyst-bootstrap
## Introduction
The newest network boxes can use ZTP/POAP with python scripts. (example : cisco nexus NXOS or arista EOS )
As I've fallen into Network-Automation, I felt like keeping deploying 'by hand' old boxes like cisco catalyst running IOS was a great loss of time. So I needed to find a solution for that, and here is the result.

Those scripts works only starting on cisco 3k range, it won't work on 2k switchs because they cannot exec EEM/TCL scripts.
The reason is only about Marketing stuff... if 2k can do what 3k do.. why should you buy more expensive box ?

I'm working on a perl script to do the same job for 2k switches ( that will handle 3k has well ...). Wait and see.


Here is the story:
As my understanding goes, Cisco provides 2 types of bootstrap:

 - **AUTO-INSTALL**
It's a very basic method, based on DHCP only, you send option 66 / 67 (respectivly tftp server address / config file path ) and here you go.
I've tested it, it works but 3 cons came out:
     - switches tested don't send in DHCP request their S/N so it's a pain to dl a "per-switch" config (smth can be made matching the mac-address but it doesnt scale ) 
     - It cannot handle software image upgrade
     - It cannot do the "write memory" command so you need to do it by yourself a way or another.

 - **SMART-INSTALL**
This is a good improvment againts AUTO-INSTALL, as it's handling both the software image upgrade and the custom config dl and the last write-memory.
More explanation here: https://supportforums.cisco.com/document/107076/how-use-zero-touch-smartinstall
Though I didn't test it myself, some folks at work use SMART-INSTALL and were happy with it.
One feedback I got was about software upgrade, it delete the old IOS first, then DL the new one. Works great most of the time. Most ...
It happens that smth went wrong during the copy of the new IOS - which let you with a brick.
On top of that, it wasn't enough for me: another 2 cons
     - It needs a director that act - as the name suggest - as the deployment manager.
       That director must be a specific cisco switch or router. I didn't wanted to buy a high-end sw or router to be a dhcp/tftp server.... a raspberry pi is more than enough.
     - It's Cisco centric, so I can't use that techno to deploy another hardware vendor like Arista

So I've ended up asking again and again our dear friend Google, Joe Clarkes's thread apparead and yeah, that was the solution. Here is some explanation of it.:

 - **DHCP**: send option 66/67 with a realy basic config (including the eem script)
 - **EEM script**: it's purpose is basically to download the TCL script
 - **TCL script**: the brain, which is able to update the Image, the Custom Config and do whatever you want at the bootstrap/pre-install step

## Requirements ?
 - DHCP server
 - TFTP server
 - Basic knowledge of TCL
 - Of course some experience with Cisco IOS syntax

and Tada, that's it !

## Whom it may concern ?
Any tech/admins that want to avoid deploying their IOS switches/router manually.

## What's inside the repo ?
 - My DHCP config - with an extra class for Opengear ZTP :) 
 - Boostrap.confg: contain the EEM script
 - Bootstrap_sw_ios.tcl: the TCL script 
 
## What's NOT inside the repo ?
The templating engine to build config, which is out-of-scope, won't be shown here.
FYI, I use Ansible/Python/Jinja2 to build the configs, but that's another story

## Credits
- The mini-project was massivly based on the work made by Joe Clarke from Cisco here
https://supportforums.cisco.com/blog/12218591/automating-cisco-live-2014-san-francisco
- Folks at the office for feedback and ideas.