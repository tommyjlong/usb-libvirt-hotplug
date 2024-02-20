# USB Hotplug Handler for Libvirt
This project provides a way to dynamically "pass-through" USB devices to a Libvirt managed VM (such as QEMU).  It detects USB devices that get plugged in or out of the host as well as USB devices that are reset and the project automatically updates libvirt.  It was developed and tested on an Ubuntu 22.04 system and uses udev along with bash shell scripts (this should work on other linux distributions as well) as well as with Libvirt version 8.0.0).

This Project consists of the following:
* udev rules file - (See `$man udev` and search for `RULES FILES`)
* USB Hotplug Shell Script - A linux bash shell script that dynamically adds/removes USB devices to/from a VM.
* Reattach Shell Script - A linux bash shell script to reattach USB devices to a restarted VM (whereas the host has not beem restarted).


# General Problem
Libvirt can be configured (either statically or dynamicallY) to passthrough a USB device based on the USB device's VendorID and Product ID and optionally with an additional qualifier pinning the device to the USB bus number and device number that is seen by the Host.  

When Libvirt "attaches" (passes-through) the USB device to the VM, if the additional USB bus/device number are not in the static configuration, Libvirt dynamically adds it. So in the end, Libvirt relies on the Hosts' USB Bus/Device number to identify which USB device to pass-through.  

When the USB device's Bus/Device numbers change while the VM is running, Libvirt will not pick up the change, thus leaving the VM with an inoperable USB device.  This is the problem this project is trying to fix. _It should be noted that the overall best way to handle problems such as this is to pass through a PCI USB Controller to the VM, but dedicating a controller to a VM is not always possible or feasible_.

The next section discusses various use cases that explain the problem in more detail.

# Use Cases 
* USB Device is Reset by an Application Running on the VM.  <br>
This causes the USB device to disappear and reappear on the Host and when it reappears it is assigned a different device number (bus number remains the same however).  Libvirt does not pick up on this change.
* USB Device can be manually unplugged/plugged back in (say to clear it out of being in some kind of  stuck state for some reason).
Replugging also results in the device being assigned a different device number. The bus number remains the same unless the device is plugged into a different slot which could be on a different bus, in which case the bus number will change as well. Libvirt does not pick up on this change.
* Rebooting Host Assigns Different Bus/Device Number.  
When the Host reboots, it starts discoverying USB buses and devices on each bus and arbitrarily assigns the bus a number and the device a number.  If there are no changes in the way devices are plugged into the system from one reboot to another, these numbers generally stay the same, but there is no guarantee.  If a new USB device is plugged in in-between reboots, the device numbers are likely to change.  When the VM is later started, Libvirt can handle this as long as the Bus/Device number is not statically configured, but if it is, then it may not have the correct Bus/Device number configured.
* Mix Use of Multiple USB Devices with the Same Vendor and Product ID <br>
This case involves one (or more) USB device(s) with the same Vendor/Product ID that is to be passed-through, but another (or more) USB device with the same Vendor/Product ID is not to be passed through as it is used by either the Host or another VM.  

  As a notable example, it is quite common to see USB sticks that use the CP210x USB-to-serial chip to have the same Vendor/Product ID (shows up generally as 0x10c4/0xea60) across different vendors as the vendor of the USB device did not reprogram the Vendor/Product ID eeprom of the CP201x.

  If Libvirt is statically configured with only the Vendor/Product ID, then on startup, it will see multiple USB devices with the same Vendor/Product ID and won't know which ones need to be passed-through, so it will stop and not bring up the VM.  A solution to this is to add the optional Bus/Device number to the static configuration.  However this scheme falls apart if the Bus/Device number changes afterward.

* VM Restarts <br>
There is no additional problem about this use case that has not been already been covered above.  It is mentioned here only for the purposes that this project is intended to also handle this use case.

# Installation and Configuration
## Determining Attributes for udev Rules File:
On the host, run the following command: 
```
$udevadm monitor --kernel --property --subsystem-match=usb
monitor will print the received events for:
KERNEL - the kernel uevent
```
then insert the USB Device (should see events like the following):
```
KERNEL[172549.864455] add      /devices/pci0000:00/0000:00:1d.0/usb2/2-1/2-1.6/2-1.6:1.0 (usb)
ACTION=add
DEVPATH=/devices/pci0000:00/0000:00:1d.0/usb2/2-1/2-1.6/2-1.6:1.0
SUBSYSTEM=usb
DEVTYPE=usb_interface
PRODUCT=10c4/ea60/100
....
```
then remove the USB Device (should see events like the following):
```
KERNEL[172351.382438] remove   /devices/pci0000:00/0000:00:1d.0/usb2/2-1/2-1.6 (usb)
ACTION=remove
DEVPATH=/devices/pci0000:00/0000:00:1d.0/usb2/2-1/2-1.6
SUBSYSTEM=usb
DEVNAME=/dev/bus/usb/002/006
DEVTYPE=usb_device
PRODUCT=10c4/ea60/100
TYPE=0/0/0
....
```

Copy the `PRODUCT` string as it is available for both "add" and "remove" and will be used by udev rules to identify the USB device type that will be used in this project.
## udev Rules File
Install the `99-libvirt-hotplug-dongles.rules` in `/etc/udev/rules.d/` directory.<br>

Each line in the rules files should looks like:<br>
`SUBSYSTEM=="usb", ENV{PRODUCT}=="10c4/ea60/100",  RUN+="/opt/udev-scripts/usb-libvirt-hotplug.sh hassio"` <br>

where `10c4/ea60/100`is the `PRODUCT` string found earlier. <br> 
_Note: It may be tempting to use other environmental/attributes such as `ID_VENDOR_ID` and `ID_MODEL_ID`, but these appear not to be available on device removal._

Next, have udev update these rules by running:<br>
`sudo udevadm control --reload-rules`

In the RUN section, specify the directory full path name where usb-libvirt-hotplug.sh resides (in this example it resides at /opt/udev-scripts/) and also specify the Libvirt domain name (in this example it is `hassio` ).
## usb-libvirt-hotplug.sh
Place this script in the directory specified in the udev rules file, and give it executable permissions (ex. `$chmod u+x usb-libvirt-hotplug.sh`).  In this example, it is placed in `\opt\udev-scripts`.<br>

Open the shell script and provide the following configurations:
* FILEPATH - This is the directory that the script will use to manage XML files.  In this example its the same directory that the script resides in which is `FILEPATH="/opt/udev-scripts/"`.
* Serial ID Matching - There are some uses cases where Vendor/Product ID is not sufficient, and a Serial ID can be used to further identify a USB device.  If such is the case, set `MATCH_SERIAL_ID=1` and configure a "stick" with the `IDI_SHORT_SERIAL` for that USB device.  The IDI_SHORT_SERIAL can be found by using the command (with the USB device plugged in):<br>
`$udevadm info /dev/X` where X is the device file for the USB Device (example `/dev/ttyUSB0`).<br>

As an example:
```
$udevadm info /dev/ttyUSB0
.....
E: ID_BUS=usb
E: ID_MODEL=SkyConnect_v1.0
E: ID_MODEL_ENC=SkyConnect\x20v1.0
E: ID_MODEL_ID=ea60
E: ID_SERIAL=Nabu_Casa_SkyConnect_v1.0_2eba2b499514ed11a6d5b68be054580b
E: ID_SERIAL_SHORT=2eba2b499514ed11a6d5b68be054580b
E: ID_VENDOR=Nabu_Casa
...
```
Here the  stick configuration in the script would be:<br>
`declare -a stick2=("hassio" "10c4:ea60" "2eba2b499514ed11a6d5b68be054580b")`
Note: Thus far in this version of the shell script, "hassio" and "10c4:ea60" are just placeholders for the script and not yet used as it is here only for future possible purposes.

## reattach-usb-to-domain.sh
This script is to be invoked manually after a VM has likewise been manually restarted.  When invoked, it must include the Libvirt domain name.  Example `./reattach-usb-to-domain.sh hassio`.

This script is intended to reside in the same directory as the usb-libvirt-hotplug.sh. <br>
It should be given executable permission (ex. `$chmod u+x reattach-usb-to-domain.sh`).

Only one item needs configuration within the script:
* FILEPATH
This is the directory the script will use to find XML files.  In this example its the same directory that the script resides in which is `FILEPATH="/opt/udev-scripts/"`.

# Theory of Operation
* udev (Dynamic Device Management) - udev uses a daemon to monitor for hardware device changes in the system.  The changes seen by udev include USB devices coming and going from the system.  When a USB device comes or goes, udev will build up a list of environmental variables that will be passed along the way to any scripts that are called. Most of these variables pertain to characteristics of the USB device, but some also include things like the "Action" udev is performing.  You can see these if you run the command <br>
  `$ udevadm monitor --kernel --property --subsystem-match=usb` and unplug, replug the USB device.

  When udev sees changes in the system it will run the `99-libvirt-hotplug-dongles.rules` file.   
* The rules file provides rules, each of which match on:
  * USB based system changes (not PCI changes, nor others)
  * Vendor ID and Product ID of the USB device <br>
  
  If there is a match, the rule will have a corresponding "RUN" action which will call the usb-libvirt-hotplug.sh script and designate which libvirt domain the RUN will apply to.
* When usb-libvirt-hotplug.sh is called, udev will pass in several USB variables characterizing the device, and it will also pass in which action udev is performing.  However only "add" and "remove" actions are honored by the `usb-libvirt-hotplug.sh` script.  

* `usb-libvirt-hotplug.sh` - The script will perform the following (Note that `echo` outputs are sent to syslog):
  * Configuration - The script requires a little bit of configuration:
    * Directory - a directory that the script lives in and to be used for managing sub-directories where each subdirectory will correspond to a Libvirt Domain (VM name).
    * USB Device Description - A device's Vendor/Product ID and Serial number (ID_SERIAL_SHORT) can be configured for each USB device the script is to handle.  This is not strictly required.
  * Will check that certain environmental parameters and the domain name are passed in, and if missing will exit.
  * Serial ID Check - The script will next look to see if a USB device's serial ID is to be verified. It is optional and not strictly required, but should be used if there are multiple USB devices with the same Vendor/Product-ID.  If the serial ID is to be verified, the device's ID_SERIAL_SHORT id is to be configured inside the script.  It is compared to the ID_SERIAL_SHORT that udev passes in to this script and if there is no match, the script silently exits.
  * Adding a Device<br>
  Once it is determined that the USB device is to be added, the script will build an xml file corresponding to Libvirt's USB passthrough configuration which will include the Vendor/Product ID and Bus/Device number seen by the host.  The file created is placed in a directory with the name of the domain.  The XML file itself is named `<bus>-<device>-<serial_number>.xml`.  This naming is used to track the specific USB device coming and going.  Before this is done, the script will first look to see if there is a remnant existing XML file with the same <serial_number> in ths name and if it finds one it will delete it.  Remant files are generally left over if the Host suddenly shutsdown say due to loss of power.

    A virsh call (a libvirt CLI command) is then made to "attach" this USB device to the domain.  virsh uses a socket when communicating with the libvirt daemon and the script verifies that the socket is open.  On Host bootup, this script is being called as USB devices are being discovered, but the libvirt daemon may not yet have its socket open.  As such, the script checks that the socket is open and if not, it loops through this check once a second for up to 2 minutes.  If the socket never opens, the script exits.  As observed in my system, on bootup it does not take long for the socket to open, but it may take many seconds to get a response back and ultimately the script may get put into a spawned task by the system because of this wait time.
  * Removing a Device <br>
  When a USB device is removed, the script will note which Bus/Device number the device used (along with the domain name), and will lookup an XML file in the `<domain>` subdirectory with the `<bus>-<device>` portion of the name.  If it finds a match, it will make a virsh call to "detach" the device using the XML for the domain.  Note that if a USB device that is being removed has a matching Vendor/Product ID but was not intended to be used by the VM, then it would not have a matching Bus/Dev numer in the XML file name, and consequently no detachment attempt is made. (Note: that when a USB device is removed, udev does not supply a serial ID in the environmental variables it passes to the script, so serial number can not be used to track a device on removal).

  The script is configured with a few things and these are discussed in the "Installation" section.

* reattach-usb-to-domain.sh - When the VM is restarted long after the host system has been running, there is nothing to trigger udev to refresh the scripts.  Although libvirt has "hooks" for calling scripts after it has started, I could not get it to call the script as it resulted in an error (Note: the hook is sychronous so calling the usb-libvirt-hotplug script has to be called as a background task).  Because I could not get this to work, this script was developed so that could be called to re-attach devices to the VM.  The script goes through the XML files that usb-libvirt-hotplug created and calls virsh to do the attachments.

# Credits
- I first came across this idea from a script used by Reddit user MacGyverNL https://www.reddit.com/r/VFIO/comments/gib29u/comment/fqdlo6a/ 
- MacGyverNL's script originally came from Olav Morken https://github.com/olavmrk/usb-libvirt-hotplug
# License
- MIT

