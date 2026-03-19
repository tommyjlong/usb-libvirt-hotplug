# USB Hotplug Handler for Libvirt
This project provides a way to dynamically "pass-through" USB devices to a Libvirt managed VM (such as QEMU).  It detects USB devices on host bootup, USB devices that get plugged in or out of the host, as well as USB devices that are reset, with the result being that libvirt is automatically updated for those devices.  It was developed and tested on Ubuntu 22.04 and 24.04 systems and uses udev along with bash shell scripts (this should work on other linux distributions as well) and was tested with Libvirt versions 8.0.0, and 10.0.0.

This Project consists of the following:
* udev rules file - (See `$man udev` and search for `RULES FILES`)
* USB Hotplug Shell Script - A linux bash shell script that dynamically adds/removes USB devices to/from a VM.
* Reattach Shell Script - A linux bash shell script to reattach USB devices to a restarted VM (whereas the host has not beem restarted).
* SystemD Service File - A SystemD service file is used on host boot-up and waits for Libvirt Daemon to come on-line.  Once on-line, a Startup Script is called.  
* Startup Script - A Startup script is used to call the Reattach Shell script for each VM.


# General Problem
Libvirt can be configured (either statically or dynamically) to passthrough a USB device based on the USB device's VendorID and Product ID and optionally with an additional qualifier pinning the device to the USB bus number and device number that is seen by the Host.  

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
This case involves two (or more) USB device(s) with the same Vendor/Product ID, either all of which are to be passed-through, or one (or more) that is to be passed through but the other(s) are not (as these are used by either the Host or another VM).  

  As a notable example, it is quite common to see USB sticks that use the CP210x USB-to-serial chip to have the same Vendor/Product ID (shows up generally as 0x10c4/0xea60) even though they are made by different vendors.  This is because the vendor of the USB device did not reprogram the Vendor/Product ID eeprom of the CP201x.

  If Libvirt is statically configured with only the Vendor/Product ID, then on startup, it will see multiple USB devices with the same Vendor/Product ID and won't know which ones need to be passed-through, so it will stop and not bring up the VM.  A solution to this is to add the optional Bus/Device number to the static configuration.  However this scheme falls apart if the Bus/Device number changes afterward.

* VM Restarts <br>
There is no additional problem about this use case that has not been already been covered above.  It is mentioned here only for the purposes that this project is intended to also handle this use case.

# Installation and Configuration

## udev Rules File
In the new version 2.0, the udev Rule in `99-libvirt-hotplug-dongles.rules` is setup to pass all USB events to the `usb-libvirt-hotplug.sh` and the latter contains configurable information for each USB device of interest.  One simply needs to configure the path to the `usb-libvirt-hotplug.sh` file. <br><br>
Install the `99-libvirt-hotplug-dongles.rules` in `/etc/udev/rules.d/` directory.<br>

Configure the path of the actual location of the `usb-libvirt-hotplug.sh` file (in this example it is located at /opt/udev-scripts/):<br>
`SUBSYSTEM=="usb",  RUN+="/opt/udev-scripts/usb-libvirt-hotplug.sh"`
<br><br>
Next, have udev update these rules by running:<br>
`sudo udevadm control --reload-rules`

## usb-libvirt-hotplug.sh
Place this script in the directory specified in the udev rules file, and give it executable permissions (ex. `$chmod u+x usb-libvirt-hotplug.sh`).  In this example, it is placed in \opt\udev-scripts.<br>

This shell script contains a table that is to be configured for the USB devices of interest to Libvirt.  Here is an example:
```
#------------------ DOMAIN---VendorID:ProductID--Serial Number
declare -a stick1=("VM1" "VEN1:PROD1" "DUMMYSERIAL1")
declare -a stick2=("hassio" "10c4:ea60" "2eb123456784ed11a6d5b68be054580b")
declare -a stick3=("hassio" "10c4:ea60" "de5123456785ed11ad29cf8f0a86e0b4")
declare -a stick4=("hassio" "0658:0200" "0658_0200")
declare -a stick5=("VM2" "VEN4:PROD4" "DONT_KNOW")
declare -a groups=("stick1" "stick2" "stick3" "stick4" "stick5" )
```
The "stick" parameters to be configured consist of:
* DOMAIN <br> 
  This is the Libvirt domain name of the VM.  In this example one of the VMs is named `hassio` for 3 of the USB devices, 
* Vendor-ID:Product-ID <br>
  This is the Vendor-ID and Product-ID of the USB device.  The format is as shown with two IDs together separated by a `:`.
* Serial Number of the USB Device <br>
  This is the serial number of the USB device. There are some uses cases where Vendor/Product ID is not sufficient, and a Serial ID can be used to further identify a USB device.  If this is not the case, then configure the serial number as `"DONT_KNOW"`.  If such is the case, configure a "stick" with the `IDI_SHORT_SERIAL` for that USB device.  The IDI_SHORT_SERIAL can be found by using the command (with the USB device plugged in):<br>
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
  Note: Although a serial number is not required to be configured, this script relies on a device having a serial number. If the device does not have ID_SERIAL_SHORT, then the script will try and use it's ID_SERIAL. <br><br>
Group <br>
  The group is just an array of the USB "sticks" that have been configured in the table.  If more sticks are needed in the table, then also include them in the group array. 
<br><br>
Note: "FILEPATH" is the full pathname/directory the script resides in and this is self-determined by the script.  This is the directory that the script will use to manage XML files for each domain.  If for some reason this doesn't work, one can manually configure it, for example: `FILEPATH="/opt/udev-scripts/"`.

## reattach-usb-to-domain.sh
This script is to be invoked manually after a VM has likewise been manually restarted.  When invoked, it must include the Libvirt domain name.  Example `./reattach-usb-to-domain.sh hassio`.

This script is intended to reside in the same directory as the usb-libvirt-hotplug.sh. <br>
It should be given executable permission (ex. `$chmod u+x reattach-usb-to-domain.sh`).

Only one item needs configuration within the script:
* FILEPATH
This is the directory the script will use to find XML files.  In this example its the same directory that the script resides in which is `FILEPATH="/opt/udev-scripts/"`.

## startup-reattach.sh
This script is to be invoked by SystemD at host startup time once the Libvirt daemon is available. This script is intended to reside in the same directory as the usb-libvirt-hotplug.sh. It should be given executable permission (ex. `$chmod u+x reattach-usb-to-domain.sh`). <br><br>
The script is to be configured for each Libvirt domain of interest: <br>
`DOMAIN_LIST=("domain1" "domain2" "domain3")` <br>
for example: <br>
`DOMAIN_LIST=("hassio")`

## reattach-usb-to-vm.service
This is the systemD service file that is used at host startup to wait for libvirt daemon to become available.  Once it becomes available it will call the "startup-reattach.sh" script.  The "ExecStart" should be configured with the full pathname to reach the script.  Here is an example:
```
[Unit]
Description=Reattach USB Devices to Libvirt After Startup
After=libvirtd.service
Requires=libvirtd.service

[Service]
Type=oneshot
ExecStart=-/opt/udev-scripts/startup-reattach.sh
#RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```
As an example for how to use this, one can place this file at `etc/systemd/system/reattach-usb-to-vm.service`. <br>
Then reload systemd to make the daemon aware of the new configuration: `$ sudo systemctl --system daemon-reload`. <br>
Then test to see if it works: `$ sudo systemctl start reattach-usb-to-vm.service` then look at `/var/log/syslog` <br>
Then enable it so that it will be used at startup time: `$ sudo systemctl enable reattach-usb-to-vm.service`.
# Theory of Operation
* udev (Dynamic Device Management) - udev uses a daemon to monitor for hardware device changes in the system.  The changes seen by udev include USB devices coming and going from the system.  When a USB device comes or goes, udev will build up a list of environmental variables that will be passed along the way to any scripts that are called. Most of these variables pertain to characteristics of the USB device, but some also include things like the "Action" udev is performing.  You can see these if you run the command <br>
  `$ udevadm monitor --kernel --property --subsystem-match=usb` while unplugging, and replugging the USB device.

  When udev sees changes in the system it will run the `99-libvirt-hotplug-dongles.rules` file.   
* udev rules file provides rules, each of which match on:
  * USB based system changes (not PCI changes, nor others)
  
  If there is a match, the rule will have a corresponding "RUN" action which will call the usb-libvirt-hotplug.sh script.
* When usb-libvirt-hotplug.sh is called, udev will pass in several USB variables characterizing the device, and it will also pass in which action udev is performing.  However only "add" and "remove" actions are honored by the `usb-libvirt-hotplug.sh` script.  The script will perform the following (Note that `echo` outputs are sent to syslog):
  * Will check that certain environmental parameters are passed in, and if missing will exit.
  * Adding a Device<br>
    The script will next look to see if a USB device's Vendor ID and Product ID and (optionally) serial ID matches an entry in the configuration table.  If the serial ID is to be matched it is compared to the ID_SERIAL_SHORT (if available, otherwise will check ID_SERIAL) that udev passes in to this script and if there is no match, the script silently exits.  Once it is determined that the USB device is to be added, the script will build an xml file corresponding to Libvirt's USB passthrough configuration which will include the Vendor/Product ID and Bus/Device number seen by the host.  The file created is placed in a directory with the name of the domain.  The XML file itself is named `<bus>-<device>-<serial_number>.xml`.  This naming is used to track the specific USB device coming and going.  Before this is done, the script will first look to see if there is a remnant existing XML file with the same `<serial_number>` in this name and if it finds one it will delete it.  Remant files are generally left over if the Host suddenly shutsdown say due to loss of power.

    A virsh call (a libvirt CLI command) is then made to "attach" this USB device to the domain.  virsh uses a socket when communicating with the libvirt daemon and the script verifies that the socket is open.  On Host bootup, this script is being called as USB devices are being discovered, but the libvirt daemon may not yet have its socket open.  As such, the script checks that the socket is open and if not, it will build the XML file and leave it there for the `startup-reattach.sh` script to use. This "startup-reattach" script is called once the SystemD service has determined that the libvirt daemon is ready.  Once called, this startup-reattach script will call the "reattach-usb-to-domain" script for each domain configured.
  * Removing a Device <br>
  When a USB device is removed, the script will note which Bus/Device number the device used.  It will next go through the configuration table picking up a list of libvirt domains, and will next go through the domain directories looking for an XML file with the `<bus>-<device>` portion of the name.  If it finds a match, it will make a virsh call to "detach" the device using that XML file for that domain.  (Note1: that when a USB device is removed, udev does not supply a serial ID in the environmental variables it passes to the script, so serial number can not be used to track a device on removal.  Vendor/Product ID is not sufficient: If a USB device that is being removed is not intended for use by a VM but nevertheless has a Vendor/Product ID that is used by a VM, then these IDs alone could not be used to determine whether to detach (or not) from a VM.  However having a matching Bus/Dev numer in the XML file name would). 

* reattach-usb-to-domain.sh - When a VM is restarted long after the host system has been running, there is nothing to trigger udev to refresh the scripts.  Although libvirt has "hooks" for calling scripts after a VM has started, I could not get it to call the script as it resulted in an error (Note too: the hook is sychronous so calling the usb-libvirt-hotplug script which in turn makes a socket call to libvirt doesn't work so this script would have to be called somehow in an asynchronous manner).  Because I could not get this to work, this script was developed so that it could be called to re-attach devices to the VM.  The script goes through the XML files for the domains that usb-libvirt-hotplug created and for each one the script calls virsh to do the attachments.  The script is intended to be called manually after a VM has been restarted.  The script is also intended to be used at host startup time by the "startup-reattach" script as USB devices found by udev may occur before libvirt is ready for them to be attached.  (Note: It is possible that this script may attempt to attach USB devices that have already been attached, in which case errors are noted but the script continues on with other USB devices).

# Appendix
## Optimizing Performance
In this version 2.0, all USB device events are sent to usb-libvirt-hotplug.sh.  However in general, not all USB devices are to be used by a virtual machine.  As an option, one could slightly optimize peformance by setting up a udev rule for only the USB devices that are to be used by a VM.  One can do this by using attributes about that particular USB device.<br><br>
Here is an example: <br>
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

The `PRODUCT` string is available for both "add" and "remove" and in this example, it will be used by udev rules to identify the USB device type of interest.

Each line in the rules files should look something like:<br>
`SUBSYSTEM=="usb", ENV{PRODUCT}=="10c4/ea60/100",  RUN+="/opt/udev-scripts/usb-libvirt-hotplug.sh"` <br>

where `10c4/ea60/100`is the `PRODUCT` string found earlier. <br> 
_Note: It may be tempting to use other environmental/attributes such as `ID_VENDOR_ID` and `ID_MODEL_ID`, but these appear not to be available on device removal._

Next, have udev update these rules by running:<br>
`sudo udevadm control --reload-rules`

In the RUN section, specify the directory full path name where usb-libvirt-hotplug.sh resides (in this example it resides at /opt/udev-scripts/).
# Credits
- I first came across this idea from a script used by Reddit user MacGyverNL https://www.reddit.com/r/VFIO/comments/gib29u/comment/fqdlo6a/ 
- MacGyverNL's script originally came from Olav Morken https://github.com/olavmrk/usb-libvirt-hotplug
# License
- MIT

