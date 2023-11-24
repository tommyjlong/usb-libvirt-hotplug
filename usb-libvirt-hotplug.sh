#!/bin/bash

#
# usb-libvirt-hotplug.sh
#
# This bash shell script can be used to hotplug USB devices to libvirt virtual
# machines from udev rules.  
#
# This can be used to attach devices when they are plugged into a
# specific port on the host machine.
# 
# This relies on a udev rule matching on a vendorID/ModelID
#   and passing in the libvirt DOMAIN name.
#
# See https://github.com/tommyjlong/usb-libvirt-hotplug
#   Credits: 
#     https://github.com/olavmrk/usb-libvirt-hotplug
#     https://www.reddit.com/r/VFIO/comments/gib29u/comment/fqdlo6a/
#
#
# Note: This script should have executable permissions.
# Note: In the future, this script may be converted to python using
#       pypi's usb-monitor
#

#
# Configurable items:
# - FILEPATH: the directory this script and xml files are to be located
# - MATCH_SERIAL_ID=1 (to use) or 0 (to not use)
#   In order to distinquish USB devices with the same VendorID/ModelID
#     where some are used with a VM and other are not
#     set this flag to 1 and configure the list of Serial IDs.
# - stickN is data representing the USB device 
#   DOMAIN: name of the VM (Note: For future use)
#   VendorID:ProductID - just that (Note: For future use)
#   Serial Number is the device's ID_SERIAL_SHORT
#     It is used when MATCH_SERIAL_ID=1.
# - groups is a list of "stickN"
#
FILEPATH="/opt/udev-scripts/"
MATCH_SERIAL_ID=1

#------------------ DOMAIN---VendorID:ProductID--Serial Number
declare -a stick1=("hassio" "VEN1:PROD1" "DUMMYSERIAL1")
declare -a stick2=("hassio" "10c4:ea60" "2eba2b499514ed11a6d5b68be054580b")
declare -a stick3=("hassio" "10c4:ea60" "de59715f6345ed11ad29cf8f0a86e0b4")
declare -a stick4=("hassio" "VEN4:PROD4" "DUMMYSERIAL4")
declare -a groups=("stick1" "stick2" "stick3" "stick4")

#
# For testing purposes, we can simulate the environmental
# variables that udev will pass to this script.
# Set SIMULATE to 1 and call this script manually.
# Set SIMULATE to 0 when udev is calling this script.
SIMULATE=0 
if [ ${SIMULATE} == 1 ]; then
  ACTION="remove"
  MAJOR=188
  MINOR=0
  #ID_VENDOR_ID="10c4" #missing on remove
  #ID_MODEL_ID="ea60"  #missing on remove
  PRODUCT=10c4/ea60/100 #present both add and remove
  BUSNUM=001 #present both add and remove
  DEVNUM=002 #present both add and remove
  DEVPATH=/devices/pci0000:00/0000:00:1d.0/usb2/2-1/2-1.6
  SUBSYSTEM="usb"
  #DEVTYPE="usb_interface"
  DEVTYPE="usb_device"
  ID_SERIAL_SHORT="de59715f6345ed11ad29cf8f0a86e0b4" #missing on remove
fi


# Abort script execution on errors
set -e

#
# Setup to send output to syslog
#
PROG="$(basename "$0")"
if [ ! -t 1 ]; then
  # stdout is not a tty. Send all output to syslog.
  coproc logger --tag "${PROG}"
  exec >&${COPROC[1]} 2>&1
fi


DOMAIN="$1"
if [ -z "${DOMAIN}" ]; then
  echo "Missing libvirt domain parameter for ${PROG}." >&2
  exit 1
fi

DOMAIN_DIR="${DOMAIN}/"

#
# Do some sanity checking of the udev environment variables.
#

if [ -z "${SUBSYSTEM}" ]; then
  echo "Missing udev SUBSYSTEM environment variable." >&2
  exit 1
fi
if [ "${SUBSYSTEM}" != "usb" ]; then
  echo "Invalid udev SUBSYSTEM: ${SUBSYSTEM}" >&2
  echo "You should probably add a SUBSYSTEM=\"usb\" match to your udev rule." >&2
  exit 1
fi
if [ -z "${DEVTYPE}" ]; then
  echo "Missing udev DEVTYPE environment variable." >&2
  exit 1
fi
if [ "${DEVTYPE}" == "usb_interface" ]; then
  echo "DEVTYPE 'usb_interface' is being ignored."
  # This is normal -- sometimes the udev rule will match
  # usb_interface events as well.
  exit 0
fi
if [ "${DEVTYPE}" != "usb_device" ]; then
  echo "Invalid udev DEVTYPE: ${DEVTYPE}" >&2
  exit 1
fi

if [ -z "${MAJOR}" ]; then
  echo "Missing udev MAJOR environment variable." >&2
  exit 1
fi
if [ -z "${MINOR}" ]; then
  echo "Missing udev MINOR environment variable." >&2
  exit 1
fi
if [ -z "${PRODUCT}" ]; then
  echo "Missing udev PRODUCT environment variable." >&2
  exit 1
else
  echo PRODUCT: $PRODUCT
  DERIV_VENDOR_ID=$( echo $PRODUCT | cut -d "/" -f 1 )
  DERIV_MODEL_ID=$( echo $PRODUCT | cut -d "/" -f 2 )
fi

#
# USB Bus number and Device number handling
#
if [ -z "${BUSNUM}" ]; then
  echo "Missing udev BUSNUM environment variable." >&2
  exit 1
fi
if [ -z "${DEVNUM}" ]; then
  echo "Missing udev DEVNUM environment variable." >&2
  exit 1
fi
#
# Convert udev bus and device number (starts at 0 and has 3 leading 0 digits)
# to USB bus and device number (starts at 1, no leading 0s)
BUSNUM=$((10#${BUSNUM}))
#USBBUSNUM=$((busnum + 1))
DEVNUM=$((10#${DEVNUM}))
#USBDEVNUM=$((devnum + 1))

#
# XML elements handling
#
XML="
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source startupPolicy='optional'>
    <vendor id='0x${DERIV_VENDOR_ID}' />
    <product id='0x${DERIV_MODEL_ID}' />
    <address bus='${BUSNUM}' device='${DEVNUM}' />
  </source>
</hostdev>
"

#
# Action Handling
#
if [ -z "${ACTION}" ]; then
  echo "Missing udev ACTION environment variable." >&2
  exit 1
fi

if [ "${ACTION}" == 'add' ]; then
  COMMAND='attach-device'
  if [ $MATCH_SERIAL_ID == 1 ]; then
    found=0
    for group in ${groups[@]}; do
      lst="$group[@]"  #don't expand this w. curly brackets
     #echo "group name: ${group} with group members: ${!lst}"
     #echo Stick N: ${!lst}
      stick=("${!lst}")
     #echo "Domain: ${stick[0]}"
     #echo "IDs: ${stick[1]}"
     #echo "Serial: ${stick[2]}"
      config_serial="${stick[2]}"
     #echo Stick1: ${!lst[0]}
      if [ ${ID_SERIAL_SHORT} == ${config_serial} ]; then
        echo "Adding: Matching serial id: ${config_serial} found."
        found=1
        break
      fi
    done

    if [ $found == 0 ]; then
      echo "Adding: Matching serial id ${ID_SERIAL_SHORT} not found; ignoring."
      exit 0
    fi
  fi

  #
  # We'll use a subdirectory for each domain, so check to see
  # if one exists, and if not, then create one
  #
  if [ ! -d "${FILEPATH}${DOMAIN}" ]; then
    echo "Create directory ${FILEPATH}${DOMAIN_DIR}"
    mkdir "${FILEPATH}${DOMAIN_DIR}"
  fi

  #
  # Whether serial-id is used for matching or not, we'll create
  # an xml file using device's serial id as part of the name.
  # But first, look for any previous file names containing this serial-id
  #   and remove them (likely caused by power outage).
  set +e  #The next line will exit 1 if no match so ignore error
  XML_FILE_LIST=$(ls ${FILEPATH}${DOMAIN_DIR}*.xml 2>/dev/null | grep ${ID_SERIAL_SHORT})
  set -e
  if [ ! -z "${XML_FILE_LIST}" ]; then
    echo "Removing extraneous files: ${XML_FILE_LIST}" >&2
    rm $XML_FILE_LIST
  fi

  #Create XML file for this USB device
  FILENAME=${BUSNUM}-${DEVNUM}-${ID_SERIAL_SHORT}
  echo ${XML} > ${FILEPATH}${DOMAIN_DIR}${FILENAME}.xml

elif [ "${ACTION}" == 'remove' ]; then
  echo "Bus/Dev: ${BUSNUM}/${DEVNUM}" >&2
  #Look for file with name containing BUSNUM-DEVNUM*
  set +e  #The next line will exit 1 if no match so ignore error
  FILE_PATH_NAME=$(ls ${FILEPATH}${DOMAIN_DIR}*.xml 2>/dev/null | grep ${BUSNUM}-${DEVNUM})
  set -e
 #FILENAME=${BUSNUM}-${DEVNUM}
 #FILE=${FILEPATH}${FILENAME}
 #if ! test -f "$FILE"; then
  if ! test -f "$FILE_PATH_NAME"; then
   #echo "File: $FILE_PATH_NAME does not exist." >&2
    echo "XML file w. orig Bus/Dev in name does not exist. Can't detach." >&2
    exit 1
  else
    COMMAND='detach-device'
    FILECMD='rm'
   #$FILECMD ${FILE}
    $FILECMD ${FILE_PATH_NAME}
  fi
else
  echo "udev ACTION: ${ACTION} is being ignored" >&2
  exit 0
fi

#echo PROG is: $PROG
#echo DEVPATH is: $DEVPATH
#echo FILECMD is: $FILECMD
#echo FILENAME is: $FILENAME
#$FILECMD $FILEPATH$FILENAME

# Before Running virsh 
# Make sure the socket is available, otherwise get 
#   error: failed to connect to the hypervisor
#   error: Failed to connect socket to '/var/run/libvirt/libvirt-sock': No such file or directory
# On Host bootup, poll socket every 1 second up to some maximum.

echo "Test for libvirt socket availability" >&2
TIME_WAIT_FOR_SOCKET=120
i=0
while [ $i -ne ${TIME_WAIT_FOR_SOCKET} ]
do
  i=$(($i+1))
  if [ -S /run/libvirt/libvirt-sock ]; then
    echo "Libvirt socket is open" >&2
    break
  else
    if [ ${i} == 1 ]; then
      echo "Waiting ${TIME_WAIT_FOR_SOCKET} secs for libvirt socket to open" >&2
    fi
    sleep 1
  fi
done
if [ ${i} -ge ${TIME_WAIT_FOR_SOCKET} ]; then
  echo "Time out waiting for socket" >&2
  exit 1
fi

echo "Running virsh ${COMMAND} ${DOMAIN} "
echo "       for USB vendor=0x${DERIV_VENDOR_ID} product=0x${DERIV_MODEL_ID} bus=${BUSNUM} device=${DEVNUM}:" >&2
#echo "       using XML elements:"
#cat /dev/stdin <<END
#virsh "${COMMAND}" "${DOMAIN}" --persistent /dev/stdin <<END
#virsh "${COMMAND}" "${DOMAIN}" /dev/stdin <<END
#<hostdev mode='subsystem' type='usb' managed='yes'>
  #<source startupPolicy='optional'>
    #<vendor id='0x${DERIV_VENDOR_ID}' />
    #<product id='0x${DERIV_MODEL_ID}' />
    #<address bus='${BUSNUM}' device='${DEVNUM}' />
  #</source>
#</hostdev>
#END

virsh "${COMMAND}" "${DOMAIN}" /dev/stdin <<END
${XML}
END
