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
# This script relies on a udev rule matching on USB system
#   and calling this script.
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
# Version 2.0

#
# Configurable items:
# - stickN is data representing the USB device 
#   DOMAIN: name of the Libvirt VM.
#   VendorID:ProductID - just that.
#   Serial Number is the device's ID_SERIAL_SHORT.
#     The Serial Number is used in order to distinquish USB devices with the same VendorID/ModelID.
#     If this is not needed, set the Serial Number to "DONT_KNOW".
#     Note: This script relies on a device having a serial number.
#      If the device does not have ID_SERIAL_SHORT, then the script will use it's ID_SERIAL.
# - groups is a list of "stickN"
#


#------------------ DOMAIN---VendorID:ProductID--Serial Number
declare -a stick1=("hassio" "VEN1:PROD1" "DUMMYSERIAL1")
declare -a stick2=("hassio" "10c4:ea60" "2eb123456784ed11a6d5b68be054580b")
declare -a stick3=("hassio" "10c4:ea60" "de5123456785ed11ad29cf8f0a86e0b4")
declare -a stick4=("hassio" "0658:0200" "0658_0200")
declare -a stick5=("hassio" "VEN4:PROD4" "DONT_KNOW")
declare -a groups=("stick1" "stick2" "stick3" "stick4" "stick5" )

#
# For testing purposes, we can simulate the environmental
# variables that udev will pass to this script.
# Set SIMULATE to 1 and call this script manually.
# Set SIMULATE to 0 when udev is calling this script.
SIMULATE=0 
if [ ${SIMULATE} == 1 ]; then
  ACTION="add"
 #ACTION="remove"
  MAJOR=188
  MINOR=0
  #ID_VENDOR_ID="10c4" #missing on remove
  #ID_MODEL_ID="ea60"  #missing on remove
  PRODUCT=10c4/ea60/100 #present both add and remove
 #PRODUCT=10c4/ea61/100 #present both add and remove.  But not in config table.
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

#Self-determine the directory this script resides in and will use for its operations.
#  One can set this manually.
#FILEPATH="/opt/udev-scripts/"
FILEPATH=$(dirname "$(realpath $0)")/
#echo "Operating in Directory: $FILEPATH"

#
# Do some sanity checking of the udev environment variables passed in.
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
VEN_PRODUCT=$DERIV_VENDOR_ID:$DERIV_MODEL_ID

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
  echo "Adding USB Device. Search Config Table for matching USB device."
  #Not all devices have short form of serial id
  if [ -z "${ID_SERIAL_SHORT}" ]; then
    ID_SERIAL_SHORT=${ID_SERIAL}
  fi

  #Search config table for a match
  found=0
  for group in ${groups[@]}; do
    lst="$group[@]"  #don't expand this w. curly brackets
   #echo "  group name: ${group} with group members: ${!lst}"
   #echo Stick N: ${!lst}
    stick=("${!lst}")
   #echo "  Domain: ${stick[0]}"
    config_domain="${stick[0]}"
   #echo "  IDs: ${stick[1]}"
    config_ven_prod_id="${stick[1]}"
   #echo "  Serial: ${stick[2]}"
    config_serial_id="${stick[2]}"
   #echo Stick1: ${!lst[0]}
    if [ ${config_ven_prod_id} == ${VEN_PRODUCT} ]; then
      echo "  Matched vendor product ${VEN_PRODUCT}"
      found=1
      if [ ${config_serial_id} != "DONT_KNOW" ]; then
       #if [ ${stick[2]} == ${ID_SERIAL_SHORT} ]; then
        if [ ${config_serial_id} == ${ID_SERIAL_SHORT} ]; then
          echo "  Matched serial short"
        else
          echo "    but didn't match required serial short"
          found=0
        fi
      else
          echo "    Skipping serial short match."
      fi
    fi
    if [ $found == 1 ]; then
      break
    fi
   #echo "  No match."
  done

  if [ $found == 0 ]; then
    echo "USB Device to add not matched in config table. Silently exiting." >&2
    exit 0
  fi

  DOMAIN=${config_domain}
  DOMAIN_DIR=${DOMAIN}/
 #echo "DOMAIN DIR= $DOMAIN_DIR"
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
  echo "Created new XML File: ${FILEPATH}${DOMAIN_DIR}${FILENAME}.xml"

elif [ "${ACTION}" == 'remove' ]; then
  echo "Removing USB device for Bus/Dev: ${BUSNUM}/${DEVNUM}" >&2
  #Looking in domain directories for an XML file to remove with matching busnum and devnum in their filename.
  #  Get the domain directoriy names from the Config table.
  domain_dir_list=()
  found=0
  for group in ${groups[@]}; do
    lst="$group[@]"  #don't expand this w. curly brackets
   #echo "group name: ${group} with group members: ${!lst}"
    stick=("${!lst}")
   #echo "Domain: ${stick[0]}"
    DOMAIN="${stick[0]}"
    DOMAIN_DIR="${DOMAIN}/"
    #See if domain directory is already in the list (if so its already been checked so skip)
    if [[ " ${domain_dir_list[@]} " =~ " $DOMAIN_DIR " ]]; then
       #echo "domain directory: '$DOMAIN_DIR' has already been checked, skipping..."
        : #do nothing
    else
        domain_dir_list+=("${DOMAIN_DIR}")
       #echo "domain dir list= ${domain_dir_list[@]}"
  
        set +e  #The next line will exit 1 if no match so ignore error
        FILE_PATH_NAME=$(ls ${FILEPATH}${DOMAIN_DIR}*.xml 2>/dev/null | grep ${BUSNUM}-${DEVNUM})
        set -e
       #ls ${FILEPATH}${DOMAIN_DIR}*.xml
        if test -f "$FILE_PATH_NAME"; then
          found=1
          break
        fi
    fi
  done

  if [ $found == 0 ]; then
   #echo "File: $FILE_PATH_NAME does not exist." >&2
    echo "XML file w. orig Bus/Dev in name does not exist. Can't detach." >&2
    exit 1
  else
    echo "File: $FILE_PATH_NAME was found. Being removed"
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
# NEW If socket is not open then don't call virsh. The xml file will still be written. 
#   Use Systemd service to wait for libvirtd to be ready then call the reattach script to make use of the xml file.
# OLD On Host bootup, poll socket every 1 second up to some maximum. No longer works.

echo "Test for libvirt socket availability" >&2
#TIME_WAIT_FOR_SOCKET=120
#i=0
#while [ $i -ne ${TIME_WAIT_FOR_SOCKET} ]
#do
#  i=$(($i+1))
#  if [ -S /run/libvirt/libvirt-sock ]; then
#    echo "Libvirt socket is open" >&2
#    break
#  else
#    if [ ${i} == 1 ]; then
#      echo "Waiting ${TIME_WAIT_FOR_SOCKET} secs for libvirt socket to open" >&2
#    fi
#    sleep 1
#  fi
#done
#if [ ${i} -ge ${TIME_WAIT_FOR_SOCKET} ]; then
#  echo "Time out waiting for socket" >&2
#  exit 1
#fi

if [ -S /run/libvirt/libvirt-sock ]; then
  echo "Libvirt socket is open" >&2
else
  echo "Libvirt socket is closed so can't attach USB devices now. >&2
  echo "A startup script that depends on libvirtd being available should be used to re-attach. >&2
  exit 0
fi

echo "Running virsh ${COMMAND} ${DOMAIN} "
echo "       for USB vendor=0x${DERIV_VENDOR_ID} product=0x${DERIV_MODEL_ID} bus=${BUSNUM} device=${DEVNUM}:" >&2

virsh "${COMMAND}" "${DOMAIN}" /dev/stdin <<END
${XML}
END
